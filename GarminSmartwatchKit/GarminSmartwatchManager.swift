//
//  GarminSmartwatchManager.swift
//  GarminSmartwatchKit
//
//  From Trio's GarminManager (Trio contributors, MIT), as a SmartwatchManager plugin.
//

import Combine
import ConnectIQ
import Foundation
import LoopKit
#if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
    import UIKit
#endif

/// Garmin (Connect IQ) as a watch plugin. **Experimental.**
///
/// It only shows data: it asks the host for no actions, so nothing goes from the
/// watch to the host. It sends the host's glucose, loop status and therapy values
/// to the chosen Connect IQ watchface or watch app and datafield, built only from
/// what it reads from the host. Devices and settings are saved in its `rawState`.
public final class GarminSmartwatchManager: NSObject {
    public static let pluginIdentifier = "GarminSmartwatchManager"
    public static let localizedTitle = LocalizedString("Garmin", comment: "Title of the Garmin watch manager")

    /// Connect IQ is set up once per launch, though the plugin may be added more than once.
    private static var isConnectIQInitialized = false

    public weak var smartwatchManagerDelegate: SmartwatchManagerDelegate?

    /// Fires on the main queue when the devices, settings or Garmin Connect's
    /// availability change, for the settings screen.
    public let stateDidChange = PassthroughSubject<Void, Never>()

    /// Garmin ConnectIQ shared instance for watch interactions.
    private let connectIQ = ConnectIQ.sharedInstance()

    /// Keeps references to watch apps (both watchface & data field) for each registered device.
    private var watchApps: [IQApp] = []

    /// A set of Combine cancellables for managing the lifecycle of various subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// Holds a promise used when the user is selecting devices (via `showDeviceSelection()`).
    private var deviceSelectionPromise: Future<[IQDevice], Never>.Promise?

    /// Subject for debouncing watch state updates
    private let watchStateSubject = PassthroughSubject<Data, Never>()

    /// Tracks which devices have completed characteristic discovery and are ready for communication.
    /// In SDK 1.8+, `deviceStatusChanged: connected` does NOT mean the device is ready.
    /// We must wait for `deviceCharacteristicsDiscovered:` before sending messages.
    private var readyDevices: Set<UUID> = []

    /// Hash of last sent data to prevent duplicate broadcasts
    private var lastSentDataHash: Int?

    /// Garmin Connect isn't installed: device selection and sending can't work.
    public private(set) var isConnectMobileMissing = false

    // MARK: - Host data

    /// What the plugin last read from the host, the only source of the watch state.
    /// Written when a read finishes, read where the watch state is prepared.
    private let hostDataLock = NSLock()
    private var storedHostData: GarminHostData?
    private var latestHostData: GarminHostData? {
        get { hostDataLock.withLock { storedHostData } }
        set { hostDataLock.withLock { storedHostData = newValue } }
    }

    /// The read in progress; a newer change replaces it, as the read gets everything.
    private var readTask: Task<Void, Never>?

    // MARK: - State

    /// The watch apps and display choices; changing them re-registers or resends as needed.
    public var settings: GarminWatchSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsDidChange(from: oldValue)
            stateDidChange.send()
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }

    /// Array of Garmin `IQDevice` objects currently tracked.
    /// Changing this property triggers re-registration and saves the devices.
    public private(set) var devices: [IQDevice] = [] {
        didSet {
            registerDevices(devices)
            stateDidChange.send()
            smartwatchManagerDelegate?.smartwatchManagerDidUpdateState(self)
        }
    }

    // MARK: - Initialization

    public override init() {
        settings = GarminWatchSettings()
        super.init()
        start(devices: [])
    }

    public init?(rawState: RawStateValue) {
        let decoder = JSONDecoder()
        settings = (rawState["settings"] as? Data).flatMap { try? decoder.decode(GarminWatchSettings.self, from: $0) }
            ?? GarminWatchSettings()
        let saved = (rawState["devices"] as? Data).flatMap { try? decoder.decode([GarminDevice].self, from: $0) } ?? []
        super.init()
        start(devices: saved.map(\.iqDevice))
    }

    private func start(devices saved: [IQDevice]) {
        if !Self.isConnectIQInitialized {
            if let scheme = Self.hostURLScheme {
                connectIQ?.initialize(withUrlScheme: scheme, uiOverrideDelegate: self)
                Self.isConnectIQInitialized = true
            }
        }
        subscribeToWatchState()
        devices = saved
    }

    /// The host app's URL scheme, which Garmin Connect calls back with the chosen devices.
    static var hostURLScheme: String? {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return types?.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
    }

    /// The host's device log.
    private func log(type: DeviceLogEntryType = .connection, _ message: String) {
        smartwatchManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: nil, type: type, message: message, completion: nil)
    }

    // MARK: - Settings Helpers

    private var currentWatchface: GarminWatchface { settings.watchface }
    private var currentDatafield: GarminDatafield { settings.datafield }
    private var isWatchfaceDataEnabled: Bool { settings.isWatchfaceDataEnabled }

    /// Returns the display name for an app UUID (watchface or datafield).
    private func appDisplayName(for uuid: UUID) -> String {
        if uuid == currentWatchface.watchfaceUUID {
            return "watchface:\(currentWatchface.displayName)"
        } else if uuid == currentDatafield.datafieldUUID {
            return "datafield:\(currentDatafield.displayName)"
        } else {
            return "unknown app"
        }
    }

    /// Returns the display name including UUID, for registration and errors.
    private func appDetailedName(for uuid: UUID) -> String {
        "\(appDisplayName(for: uuid)) (\(uuid.uuidString))"
    }

    // MARK: - Updates

    /// Prepares the watch state from the latest host data and sends it to the debounce subject.
    private func triggerWatchStateUpdate(triggeredBy trigger: String) {
        guard !devices.isEmpty, let data = watchStateData() else { return }
        watchStateSubject.send(data)
    }

    /// The watch state as the watch apps read it; `nil` before the host data is read.
    func watchStateData() -> Data? {
        guard let host = latestHostData else { return nil }
        let options = GarminWatchState.DisplayOptions(
            primaryAttributeChoice: settings.primaryAttributeChoice.rawValue,
            secondaryAttributeChoice: settings.secondaryAttributeChoice.rawValue,
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            historyCount: settings.watchface.historyCount
        )
        return try? JSONEncoder().encode(GarminWatchState.states(from: host, options: options))
    }

    /// Re-registers when the watch apps change; resends when what they show changes.
    private func settingsDidChange(from old: GarminWatchSettings) {
        if settings.watchface != old.watchface || settings.datafield != old.datafield
            || settings.isWatchfaceDataEnabled != old.isWatchfaceDataEnabled
        {
            log("Garmin watchface or data field changed, re-registering devices")
            registerDevices(devices)
        }
        triggerWatchStateUpdate(triggeredBy: "Settings")
    }

    // MARK: - Device & App Registration

    /// Registers the given devices for ConnectIQ events (device status changes) and watch app messages.
    /// It also creates and registers watch apps (watchface + data field) for each device.
    /// - Parameter devices: The devices to register.
    private func registerDevices(_ devices: [IQDevice]) {
        watchApps.removeAll()

        // Reset broadcast hash so newly registered apps receive data
        // Without this, hash deduplication could skip sending to new apps if data unchanged
        lastSentDataHash = nil

        // Note: Do NOT clear readyDevices here. The device ready state is based on BLE
        // characteristic discovery, which only happens on new connections. Re-registering
        // for app messages doesn't affect the underlying BLE connection state.

        for device in devices {
            connectIQ?.register(forDeviceEvents: device, delegate: self)

            // Register watchface if enabled
            if isWatchfaceDataEnabled,
               let watchfaceUUID = currentWatchface.watchfaceUUID,
               let watchfaceApp = IQApp(uuid: watchfaceUUID, store: UUID(), device: device)
            {
                log("Registered Garmin \(appDetailedName(for: watchfaceUUID))")
                watchApps.append(watchfaceApp)
                connectIQ?.register(forAppMessages: watchfaceApp, delegate: self)
            } else if !isWatchfaceDataEnabled {
                log("Garmin watchface data disabled, watchface not registered")
            }

            // Always register datafield (if configured)
            if let datafieldUUID = currentDatafield.datafieldUUID,
               let datafieldApp = IQApp(uuid: datafieldUUID, store: UUID(), device: device)
            {
                log("Registered Garmin \(appDetailedName(for: datafieldUUID))")
                watchApps.append(datafieldApp)
                connectIQ?.register(forAppMessages: datafieldApp, delegate: self)
            }
        }
    }

    // MARK: - Simulator Support

    #if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
        /// Mock IQDevice class for simulator testing
        /// Minimal implementation just for testing - no actual Garmin functionality
        public class MockIQDevice: IQDevice {
            private let _uuid: UUID
            private let _friendlyName: String
            private let _modelName: String

            public override var uuid: UUID { _uuid }
            public override var friendlyName: String { _friendlyName }
            public override var modelName: String { _modelName }
            public var status: IQDeviceStatus { .connected }

            public init(uuid: UUID, friendlyName: String, modelName: String) {
                _uuid = uuid
                _friendlyName = friendlyName
                _modelName = modelName
                super.init()
            }

            @available(*, unavailable) required init?(coder _: NSCoder) {
                fatalError("init(coder:) not implemented for mock device")
            }

            /// Shared simulated device UUID for consistency across the app
            public static let simulatedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                ?? UUID()

            /// Creates the standard simulated Enduro 3 device
            public static func createSimulated() -> MockIQDevice {
                MockIQDevice(
                    uuid: simulatedUUID,
                    friendlyName: "Enduro 3 Sim",
                    modelName: "Enduro 3"
                )
            }

            /// A mock Garmin Connect's answer: `<scheme>://device-select-resp?name=…&model=…&uuid=…`.
            static func parseSelection(from url: URL) -> [IQDevice] {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
                guard let name = value("name") else { return [] }
                return [MockIQDevice(
                    uuid: value("uuid").flatMap(UUID.init(uuidString:)) ?? simulatedUUID,
                    friendlyName: name,
                    modelName: value("model") ?? name
                )]
            }
        }

        /// Garmin Connect can't run in the simulator (and a local test build can set
        /// `GARMIN_MOCK_CONNECT` to use the mock on a phone): a mock Garmin Connect app
        /// (`garminconnect-mock://`) answers through the host's URL scheme like the real one,
        /// so the app switch and the callback are the same. Without it, the simulated watch is chosen.
        private func showMockDeviceSelection() {
            let scheme = Self.hostURLScheme ?? ""
            let fallback = URL(string: "\(scheme)://device-select-resp?name=Enduro%203%20Sim&model=Enduro%203")!
            guard let mock = URL(string: "garminconnect-mock://device-select?scheme=\(scheme)") else { return }
            UIApplication.shared.open(mock) { [weak self] opened in
                guard !opened else { return }
                _ = self?.watchHostDidReceiveURL(fallback)
            }
        }
    #endif

    // MARK: - Combine Subscriptions

    /// Subscribes to watch state updates with debouncing
    private func subscribeToWatchState() {
        watchStateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] data in
                self?.broadcastWatchStateData(data)
            }
            .store(in: &cancellables)
    }

    // MARK: - Parsing & Broadcasting

    /// Parses devices from Garmin Connect's device-selection callback (via the host) and
    /// updates our `devices` property.
    /// - Parameter url: The URL provided by Garmin Connect containing device selection info.
    private func parseDevices(for url: URL) {
        connectMobileIsAvailable()
        #if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
            let parsed: [IQDevice]? = MockIQDevice.parseSelection(from: url)
        #else
            let parsed = connectIQ?.parseDeviceSelectionResponse(from: url) as? [IQDevice]
        #endif
        devices = parsed ?? []
        deviceSelectionPromise?(.success(devices))
        deviceSelectionPromise = nil
    }

    /// Broadcasts watch state data to all registered apps
    private func broadcastWatchStateData(_ data: Data) {
        // Deduplicate: Use stable content-based hash (sorted JSON bytes)
        let currentHash: Int
        if let sortedData = try? JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: data, options: []),
            options: [.sortedKeys]
        ) {
            currentHash = sortedData.base64EncodedString().hashValue
        } else {
            currentHash = data.count // Fallback
        }

        if currentHash == lastSentDataHash {
            if true {
                log("Garmin broadcast skipped, data unchanged")
            }
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            log(type: .error, "Garmin watch state is not valid JSON")
            return
        }

        watchApps.forEach { app in
            guard let appUUID = app.uuid else {
                log("Skipped Garmin app without UUID")
                return
            }
            let appName = self.appDisplayName(for: appUUID)

            // Check if device is ready (SDK 1.8+ requirement)
            guard let device = app.device, readyDevices.contains(device.uuid) else {
                log("Skipped Garmin \(appName), device not ready")
                return
            }

            connectIQ?.getAppStatus(app) { [weak self] status in
                guard status?.isInstalled == true else {
                    self?.log("Garmin \(appName) not installed")
                    return
                }
                self?.log("Sending to Garmin \(appName)")
                self?.sendMessage(jsonObject as Any, to: app, appName: appName)
            }
        }

        // Update last sent hash after initiating send
        lastSentDataHash = currentHash
    }

    // MARK: - Devices

    /// Prompts the user to select one or more Garmin devices, returning a publisher that emits
    /// the final array of selected devices once the user finishes selection.
    /// - Returns: An `AnyPublisher` emitting `[IQDevice]` on success, or empty array on error/timeout.
    public func selectDevices() -> AnyPublisher<[IQDevice], Never> {
        Future { [weak self] promise in
            guard let self = self else {
                promise(.success([]))
                return
            }
            self.deviceSelectionPromise = promise
            #if targetEnvironment(simulator) || GARMIN_MOCK_CONNECT
                self.showMockDeviceSelection()
            #else
                self.connectIQ?.showDeviceSelection()
            #endif
        }
        .timeout(.seconds(120), scheduler: DispatchQueue.main)
        .replaceEmpty(with: [])
        .eraseToAnyPublisher()
    }

    /// Updates the manager's list of devices, typically after user selection or manual changes.
    /// - Parameter devices: The new array of `IQDevice` objects to track.
    public func updateDeviceList(_ devices: [IQDevice]) {
        self.devices = devices
    }

    /// Sends the given watch state data to the debounce subject for eventual broadcast.
    /// - Parameter data: JSON-encoded data representing the latest watch state.
    public func sendWatchStateData(_ data: Data) {
        watchStateSubject.send(data)
    }

    // MARK: - Helper: Sending Messages

    /// Sends a message to a given IQApp with optional progress and completion callbacks.
    /// Retries once after a short delay if the first attempt fails (SDK may need time after re-registration).
    /// - Parameters:
    ///   - msg: The data to send to the watch app.
    ///   - app: The `IQApp` instance representing the watchface or data field.
    ///   - appName: The display name of the app for logging.
    ///   - isRetry: Whether this is a retry attempt (to prevent infinite retries).
    private func sendMessage(_ msg: Any, to app: IQApp, appName: String, isRetry: Bool = false) {
        connectIQ?.sendMessage(
            msg,
            to: app,
            progress: { _, _ in },
            completion: { [weak self] result in
                switch result {
                case .success:
                    self?.log("Sent to Garmin \(appName)")
                default:
                    if isRetry {
                        self?.log(type: .error, "Sending to Garmin \(appName) failed after retry")
                    } else {
                        self?.log(type: .error, "Sending to Garmin \(appName) failed, retrying in 2 s")
                        // Retry after delay - SDK may need time after re-registration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.log("Retrying send to Garmin \(appName)")
                            self?.sendMessage(msg, to: app, appName: appName, isRetry: true)
                        }
                    }
                }
            }
        )
    }
}

// MARK: - Connect IQ delegates

extension GarminSmartwatchManager: IQUIOverrideDelegate, IQDeviceEventDelegate, IQAppMessageDelegate {
    // MARK: - IQUIOverrideDelegate

    /// Garmin Connect isn't installed: a host alert (device selection and sending
    /// can't work without it), and a warning with a link in the settings.
    public func needsToInstallConnectMobile() {
        log(type: .error, "Garmin Connect app not available; install it from the App Store")
        if let delegate = smartwatchManagerDelegate {
            let alert = Self.connectMobileMissingAlertContent()
            Task { await delegate.issueAlert(alert) }
        }
        DispatchQueue.main.async {
            self.isConnectMobileMissing = true
            self.stateDidChange.send()
        }
    }

    static let connectMobileMissingAlertIdentifier = Alert.Identifier(
        managerIdentifier: pluginIdentifier,
        alertIdentifier: "connectMobileMissing"
    )

    /// Garmin Connect missing: a warning, so time-sensitive (a host shows a plugin's alerts at most that).
    static func connectMobileMissingAlertContent() -> Alert {
        let content = Alert.Content(
            title: LocalizedString("Garmin Connect isn't installed", comment: "Garmin alert title: Garmin Connect missing"),
            body: LocalizedString("Install Garmin Connect from the App Store to choose Garmin watches and send them glucose.", comment: "Garmin alert body: Garmin Connect missing"),
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Garmin alert acknowledge button")
        )
        return Alert(
            identifier: connectMobileMissingAlertIdentifier,
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: .timeSensitive
        )
    }

    /// Withdraws the alert from the host.
    private func retractConnectMobileMissingAlert() {
        guard let delegate = smartwatchManagerDelegate else { return }
        Task { await delegate.retractAlert(identifier: Self.connectMobileMissingAlertIdentifier) }
    }

    /// Garmin Connect answered, so it's installed: the alert no longer applies.
    private func connectMobileIsAvailable() {
        guard isConnectMobileMissing else { return }
        isConnectMobileMissing = false
        retractConnectMobileMissingAlert()
        stateDidChange.send()
    }

    /// Opens Garmin Connect in the App Store.
    public func showAppStoreForConnectMobile() {
        connectIQ?.showAppStoreForConnectMobile()
    }

    // MARK: - IQDeviceEventDelegate

    /// Called whenever the status of a registered Garmin device changes (e.g., connected, not found, etc.).
    /// Note: In SDK 1.8+, `connected` does NOT mean ready for communication.
    /// Wait for `deviceCharacteristicsDiscovered:` before sending messages.
    /// - Parameters:
    ///   - device: The device whose status has changed.
    ///   - status: The new status for the device.
    public func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        // Always log connection state changes - critical for diagnosing SDK issues
        switch status {
        case .invalidDevice:
            log(type: .error, "Garmin device invalid")
            readyDevices.remove(device.uuid)
        case .bluetoothNotReady:
            log("Garmin device unavailable, Bluetooth not ready")
            readyDevices.remove(device.uuid)
        case .notFound:
            log("Garmin device not found")
            readyDevices.remove(device.uuid)
        case .notConnected:
            log("Garmin device disconnected")
            readyDevices.remove(device.uuid)
        case .connected:
            log("Garmin device connected, waiting for characteristics")
        @unknown default:
            log("Garmin device status unknown (\(status.rawValue))")
        }
    }

    /// Called when device characteristics are discovered and the device is ready for communication.
    /// This is required in SDK 1.8+ - sending before this callback may fail.
    /// - Parameter device: The device whose characteristics have been discovered.
    public func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        log("Garmin device connected and ready")
        readyDevices.insert(device.uuid)

        // Trigger a data send now that device is ready
        // This ensures newly connected devices get data promptly
        triggerWatchStateUpdate(triggeredBy: "DeviceReady")
    }

    // MARK: - IQAppMessageDelegate

    /// Called when a message arrives from a Garmin watch app (watchface or data field).
    /// If the watch requests a "status" update, the watch state is prepared again
    /// and re-send the watch state data.
    /// - Parameters:
    ///   - message: The message content from the watch app.
    ///   - app: The watch app sending the message.
    public func receivedMessage(_ message: Any, from app: IQApp) {
        guard let appUUID = app.uuid else {
            log("Ignored message from Garmin app without UUID")
            return
        }
        let appName = appDisplayName(for: appUUID)
        log("Message received from Garmin \(appName)")

        // If watch requests status update, send current data via unified path
        guard let statusString = message as? String, statusString == "status" else {
            return
        }

        // The app is asking, so answer even when nothing changed: a freshly opened
        // watch app or glance has no data until it gets a send.
        lastSentDataHash = nil

        // Use triggerWatchStateUpdate for consistent deduplication and debouncing
        // This prevents double sends when watchface request coincides with determination
        triggerWatchStateUpdate(triggeredBy: "WatchRequest")
    }
}

// MARK: - SmartwatchManager

extension GarminSmartwatchManager: SmartwatchManager {
    public var rawState: RawStateValue {
        let encoder = JSONEncoder()
        var state: RawStateValue = [:]
        state["settings"] = try? encoder.encode(settings)
        state["devices"] = try? encoder.encode(devices.map(GarminDevice.init))
        return state
    }

    public var pluginIdentifier: String { Self.pluginIdentifier }
    public var localizedTitle: String { Self.localizedTitle }
    public var isOnboarded: Bool { true }
    // A watch has no signal or operable state of its own here.
    public var inSignalLoss: Bool { false }
    public var isInoperable: Bool { false }

    @MainActor
    public func hostDataDidChange(_ changes: SmartwatchHostDataChange) {
        // The watch shows glucose, loop output, basal, sensitivity, target and the display unit.
        guard !changes.isDisjoint(with: [.glucose, .loop, .presets, .settings]),
              let delegate = smartwatchManagerDelegate
        else { return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            guard let self else { return }
            let host = await self.readHostData(from: delegate)
            guard !Task.isCancelled else { return }
            self.latestHostData = host
            self.triggerWatchStateUpdate(triggeredBy: "Host")
        }
    }

    /// Reads what the watch shows; `nil` when the readings can't be read.
    private func readHostData(from delegate: SmartwatchManagerDelegate) async -> GarminHostData? {
        let samples: [StoredGlucoseSample]
        do {
            samples = try await delegate.smartwatchManager(self, glucoseSamplesSince: Date().addingTimeInterval(-GarminHostData.historyInterval))
        } catch {
            log(type: .error, "Garmin could not read glucose: \(error.localizedDescription)")
            return nil
        }
        return GarminHostData(
            displayUnit: await delegate.smartwatchManagerGlucoseDisplayUnit(self),
            glucoseSamples: samples,
            loopState: await delegate.smartwatchManagerLoopState(self),
            scheduledBasalRate: await delegate.smartwatchManagerScheduledBasalRate(self),
            tempBasal: await delegate.smartwatchManagerTempBasal(self),
            insulinSensitivity: await delegate.smartwatchManagerInsulinSensitivity(self),
            correctionRange: await delegate.smartwatchManagerCorrectionRange(self)
        )
    }

    /// Garmin Connect's device-selection callback.
    @MainActor
    public func watchHostDidReceiveURL(_ url: URL) -> Bool {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.host == "device-select-resp" else { return false }
        parseDevices(for: url)
        return true
    }

    /// Stops sending: the watch apps get nothing more from the host.
    public func delete() async {
        await MainActor.run {
            readTask?.cancel()
            readTask = nil
        }
        latestHostData = nil
        await smartwatchManagerDelegate?.retractAlert(identifier: Self.connectMobileMissingAlertIdentifier)
        connectIQ?.unregister(forAllDeviceEvents: self)
        connectIQ?.unregister(forAllAppMessages: self)
        watchApps.removeAll()
        await smartwatchManagerDelegate?.smartwatchManagerWantsDeletion(self)
    }

    public func initializationComplete(for _: [Pluggable]) {}

    public override var debugDescription: String {
        "## GarminSmartwatchManager\n* devices: \(devices.count)\n* settings: \(settings)\n* host data: \(latestHostData == nil ? "none" : "received")"
    }

    /// Nothing to do: the alert only points to the App Store, and it goes away
    /// when Garmin Connect answers.
    public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws {}

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }
}
