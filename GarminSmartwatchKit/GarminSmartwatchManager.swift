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

// MARK: - Connect IQ Client

/// The Connect IQ calls that register and reach watch apps, behind a protocol so delivery can be
/// tested without a watch. There is deliberately no app-status call: each one is a BLE round trip.
/// From mountrcg's Garmin delivery rework (MIT).
protocol GarminConnectIQClient: AnyObject {
    func registerDevice(_ device: IQDevice, delegate: IQDeviceEventDelegate)
    func registerApp(_ app: IQApp, delegate: IQAppMessageDelegate)
    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void)
}

extension ConnectIQ: GarminConnectIQClient {
    func registerDevice(_ device: IQDevice, delegate: IQDeviceEventDelegate) {
        register(forDeviceEvents: device, delegate: delegate)
    }

    func registerApp(_ app: IQApp, delegate: IQAppMessageDelegate) {
        register(forAppMessages: app, delegate: delegate)
    }

    func send(_ message: Any, to app: IQApp, completion: @escaping (IQSendMessageResult) -> Void) {
        sendMessage(message, to: app, progress: { _, _ in }, completion: completion)
    }
}

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

    /// Registers and messages watch apps; the shared Connect IQ instance unless a test sets a spy.
    var connectIQClient: GarminConnectIQClient? = ConnectIQ.sharedInstance()

    /// Wait before the single resend of a failed message.
    var sendRetryDelay: TimeInterval = 2

    // MARK: - Delivery

    /// What an app is still owed after its send failed for good; the latest state wins. Main queue only.
    struct OwedDelivery: Equatable {
        var stateHash: Int?
    }

    /// The send result is the readiness signal: readiness never gates a send, because a missed
    /// characteristics callback would otherwise block delivery until the next reconnect.
    private(set) var owedDeliveries: [String: OwedDelivery] = [:]

    /// Apps that answered `AppNotFound`, skipped until re-registration or a message from them.
    private(set) var absentApps: Set<String> = []

    /// The only send gate, set by the SDK's device status callbacks.
    private(set) var disconnectedDevices: Set<UUID> = []

    /// Latest broadcast state, whole, sent again (as each app gets it) to apps that are owed state.
    private var lastBroadcast: Any?

    /// Apps that asked for state: the next broadcast goes to them even when unchanged, whatever an
    /// older send's completion confirms in the meantime. Consumed by that broadcast.
    private(set) var forcedStateKeys: Set<String> = []

    /// Hash of the last state each app confirmed receiving, keyed by `deliveryKey(for:)`.
    private(set) var lastSentDataHashes: [String: Int] = [:]

    /// Set on the main queue by `delete()`: nothing is sent or retried after it, whatever is still queued.
    private(set) var isDeleted = false

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

    /// Whether the host shows glucose in mmol/L, for the settings screen's labels;
    /// `false` before the host data is read.
    public var isMillimolesPerLiterHost: Bool {
        latestHostData?.displayUnit == .millimolesPerLiter
    }

    /// The read in progress; a newer change replaces it, as the read gets everything.
    private var readTask: Task<Void, Never>?

    /// The forecast lines last written to the device log; the loop state is read
    /// with every reading, the forecast is logged only when it changes.
    private var loggedForecast: [String] = []

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

    /// The host app's name as its users see it ("Trio", "Loop"), sent for the watch
    /// to show, as LupedSmartwatchKit does; `nil` if the app declares none.
    public static var hostName: String? {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name?.isEmpty == false ? name : nil
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
        guard !isDeleted, !devices.isEmpty, let data = watchStateData() else { return }
        watchStateSubject.send(data)
    }

    /// The watch state as the watch apps read it; `nil` before the host data is read.
    func watchStateData() -> Data? {
        guard let host = latestHostData else { return nil }
        let options = GarminWatchState.DisplayOptions(
            primaryAttributeChoice: settings.primaryAttributeChoice.rawValue,
            secondaryAttributeChoice: settings.secondaryAttributeChoice.rawValue,
            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
            historySpan: settings.watchface.historySpan,
            historySpacing: settings.watchface.historySpacing,
            hostName: Self.hostName,
            timeInRangePeriod: settings.isTimeInRangeEnabled ? settings.timeInRangePeriod : nil,
            timeInRangeTarget: settings.timeInRangeTarget
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
        guard !isDeleted else { return }
        watchApps.removeAll()

        // Newly registered apps get the next state even if it is unchanged.
        lastSentDataHashes.removeAll()
        // Re-registration is the retry permission for apps that answered AppNotFound.
        absentApps.removeAll()

        for device in devices {
            connectIQClient?.registerDevice(device, delegate: self)

            // Register watchface if enabled
            if isWatchfaceDataEnabled,
               let watchfaceUUID = currentWatchface.watchfaceUUID,
               let watchfaceApp = IQApp(uuid: watchfaceUUID, store: UUID(), device: device)
            {
                log("Registered Garmin \(appDetailedName(for: watchfaceUUID))")
                watchApps.append(watchfaceApp)
                connectIQClient?.registerApp(watchfaceApp, delegate: self)
            } else if !isWatchfaceDataEnabled {
                log("Garmin watchface data disabled, watchface not registered")
            }

            // Always register datafield (if configured)
            if let datafieldUUID = currentDatafield.datafieldUUID,
               let datafieldApp = IQApp(uuid: datafieldUUID, store: UUID(), device: device)
            {
                log("Registered Garmin \(appDetailedName(for: datafieldUUID))")
                watchApps.append(datafieldApp)
                connectIQClient?.registerApp(datafieldApp, delegate: self)
            }
        }
        let registeredKeys = Set(watchApps.compactMap(deliveryKey(for:)))
        owedDeliveries = owedDeliveries.filter { registeredKeys.contains($0.key) }
        forcedStateKeys.formIntersection(registeredKeys)
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
                _ = self?.hostDidReceiveURL(fallback)
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

    /// Sends the state once to every registered app that hasn't confirmed this exact state yet,
    /// each with only the parts of it that app reads.
    func broadcastWatchStateData(_ data: Data) {
        guard !isDeleted else { return }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            log(type: .error, "Garmin watch state is not valid JSON")
            return
        }
        lastBroadcast = jsonObject

        for app in watchApps {
            guard let key = deliveryKey(for: app), let device = app.device else { continue }
            let appName = appDisplayName(for: app.uuid)
            let (payload, stateHash) = appPayload(jsonObject, for: app)

            if lastSentDataHashes[key] == stateHash, owedDeliveries[key]?.stateHash == nil, !forcedStateKeys.contains(key) {
                log("Garmin \(appName) skipped, data unchanged")
                continue
            }
            forcedStateKeys.remove(key)
            // An unreachable app is owed this state instead.
            guard isReachable(key: key, device: device, appName: appName) else {
                recordOwed(for: key, stateHash: stateHash)
                continue
            }
            log("Sending state to Garmin \(appName)")
            sendMessage(payload, to: app, appName: appName, stateHash: stateHash)
        }
    }

    /// What the app reads; an app the settings don't name gets everything.
    func payloadContent(for app: IQApp) -> GarminPayloadContent {
        if app.uuid == currentWatchface.watchfaceUUID { return currentWatchface.payloadContent }
        if app.uuid == currentDatafield.datafieldUUID { return currentDatafield.payloadContent }
        return .all
    }

    /// The state as `app` gets it, and a stable hash of that (sorted JSON bytes), so an app is
    /// sent again only when what it gets changes.
    private func appPayload(_ state: Any, for app: IQApp) -> (payload: Any, hash: Int) {
        let payload = GarminWatchState.payload(state, for: payloadContent(for: app))
        let sorted = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return (payload, sorted?.hashValue ?? 0)
    }

    // MARK: - Delivery

    func deliveryKey(for app: IQApp) -> String? {
        guard let appUUID = app.uuid, let deviceUUID = app.device?.uuid else { return nil }
        return "\(appUUID.uuidString)-\(deviceUUID.uuidString)"
    }

    /// SDK completions aren't documented to arrive on main; delivery state lives there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Skipping keeps whatever the app is owed for the next trigger.
    private func isReachable(key: String, device: IQDevice, appName: String) -> Bool {
        if absentApps.contains(key) {
            log("Garmin \(appName) skipped, app not installed")
            return false
        }
        if disconnectedDevices.contains(device.uuid) {
            log("Garmin \(appName) skipped, device disconnected")
            return false
        }
        return true
    }

    private func recordOwed(for key: String, stateHash: Int?) {
        guard let stateHash else { return }
        owedDeliveries[key] = OwedDelivery(stateHash: stateHash)
    }

    /// Any delivered message proves the channel, so what the app is still owed goes out now.
    private func flushOwed(to app: IQApp, key: String, appName: String) {
        guard !isDeleted, let owed = owedDeliveries.removeValue(forKey: key) else { return }
        guard owed.stateHash != nil, let state = lastBroadcast else { return }
        let (payload, stateHash) = appPayload(state, for: app)
        if lastSentDataHashes[key] != stateHash {
            log("Sending owed state to Garmin \(appName)")
            sendMessage(payload, to: app, appName: appName, stateHash: stateHash)
        }
    }

    /// Sends again on the triggers that occur anyway (broadcast, reconnect, a message from the app)
    /// instead of timers.
    private func flushOwed(on device: IQDevice) {
        guard !isDeleted else { return }
        for app in watchApps where app.device?.uuid == device.uuid {
            guard let key = deliveryKey(for: app), !absentApps.contains(key) else { continue }
            flushOwed(to: app, key: key, appName: appDisplayName(for: app.uuid))
        }
    }

    /// An app installed or updated while the host runs answers again after a reconnect, so the
    /// device's apps are tried again instead of waiting for a re-registration.
    private func clearAbsentMarks(on deviceUUID: UUID) {
        let keys = watchApps.filter { $0.device?.uuid == deviceUUID }.compactMap(deliveryKey(for:))
        absentApps.subtract(keys)
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

    /// Sends with one resend after `sendRetryDelay` for other failures; a final failure leaves the
    /// state owed. `AppNotFound` is never resent: the app isn't installed.
    func sendMessage(_ msg: Any, to app: IQApp, appName: String, stateHash: Int? = nil, isRetry: Bool = false) {
        // Covers a resend still waiting for its delay and anything queued before `delete()`.
        guard !isDeleted else { return }
        connectIQClient?.send(msg, to: app) { [weak self] result in
            self?.onMain {
                // A late completion after `delete()` must not flush owed sends.
                guard let self, !self.isDeleted, let key = self.deliveryKey(for: app) else { return }
                switch result {
                case .success:
                    self.log("Sent to Garmin \(appName)")
                    self.absentApps.remove(key)
                    if let stateHash { self.lastSentDataHashes[key] = stateHash }
                    self.flushOwed(to: app, key: key, appName: appName)
                case .failure_AppNotFound:
                    self.log("Garmin \(appName) not installed, skipped until re-registered or heard from")
                    self.absentApps.insert(key)
                    self.recordOwed(for: key, stateHash: stateHash)
                default:
                    let reason = NSStringFromSendMessageResult(result) ?? "\(result.rawValue)"
                    if isRetry {
                        self.log(type: .error, "Sending to Garmin \(appName) failed after retry (\(reason))")
                        self.recordOwed(for: key, stateHash: stateHash)
                    } else {
                        self.log(type: .error, "Sending to Garmin \(appName) failed, retrying (\(reason))")
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.sendRetryDelay) { [weak self] in
                            self?.sendMessage(msg, to: app, appName: appName, stateHash: stateHash, isRetry: true)
                        }
                    }
                }
            }
        }
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
    /// Only a lost connection stops sends; nothing here costs a round trip to the watch.
    /// - Parameters:
    ///   - device: The device whose status has changed.
    ///   - status: The new status for the device.
    public func deviceStatusChanged(_ device: IQDevice, status: IQDeviceStatus) {
        // The SDK's callback thread is undocumented; delivery state lives on main.
        nonisolated(unsafe) let device = device
        onMain { [weak self] in self?.handleDeviceStatus(device, status: status) }
    }

    private func handleDeviceStatus(_ device: IQDevice, status: IQDeviceStatus) {
        // Always log connection state changes - critical for diagnosing SDK issues
        switch status {
        case .invalidDevice:
            log(type: .error, "Garmin device invalid")
            disconnectedDevices.insert(device.uuid)
        case .bluetoothNotReady:
            log("Garmin device unavailable, Bluetooth not ready")
            disconnectedDevices.insert(device.uuid)
        case .notFound:
            log("Garmin device not found")
            disconnectedDevices.insert(device.uuid)
        case .notConnected:
            log("Garmin device disconnected")
            disconnectedDevices.insert(device.uuid)
        case .connected:
            log("Garmin device connected")
            disconnectedDevices.remove(device.uuid)
            clearAbsentMarks(on: device.uuid)
        @unknown default:
            log("Garmin device status unknown (\(status.rawValue))")
        }
    }

    /// Called when device characteristics are discovered (SDK 1.8+). It doesn't gate sends,
    /// but a reconnect is a good moment to send what the watch apps are owed.
    /// - Parameter device: The device whose characteristics have been discovered.
    public func deviceCharacteristicsDiscovered(_ device: IQDevice) {
        nonisolated(unsafe) let device = device
        onMain { [weak self] in self?.handleCharacteristicsDiscovered(device) }
    }

    private func handleCharacteristicsDiscovered(_ device: IQDevice) {
        guard !isDeleted else { return }
        log("Garmin device connected and ready")
        disconnectedDevices.remove(device.uuid)
        // A datafield or watchface installed or updated meanwhile gets what it is owed now.
        clearAbsentMarks(on: device.uuid)
        flushOwed(on: device)

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
        // The SDK's callback thread is undocumented; the registered apps and delivery state live on main.
        // Connect IQ messages are plain property-list values.
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let app = app
        onMain { [weak self] in self?.handleMessage(message, from: app) }
    }

    private func handleMessage(_ message: Any, from app: IQApp) {
        guard !isDeleted else { return }
        guard let appUUID = app.uuid else {
            log("Ignored message from Garmin app without UUID")
            return
        }
        let appName = appDisplayName(for: appUUID)
        log("Message received from Garmin \(appName)")
        let registered = watchApps.first { $0.uuid == appUUID && $0.device?.uuid == app.device?.uuid }
        let registeredKey = registered.flatMap(deliveryKey(for:))

        // A message from the app proves the channel, so it gets what it is owed right away.
        if let registered, let registeredKey {
            absentApps.remove(registeredKey)
            flushOwed(to: registered, key: registeredKey, appName: appName)
        }

        // If watch requests status update, send current data via unified path
        guard let statusString = message as? String, statusString == "status" else {
            return
        }

        // The app is asking, so answer even when nothing changed: a freshly opened
        // watch app or glance has no data until it gets a send.
        if let registeredKey {
            lastSentDataHashes[registeredKey] = nil
            forcedStateKeys.insert(registeredKey)
        }

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
        guard !isDeleted, !changes.isDisjoint(with: [.glucose, .loop, .presets, .settings]),
              let delegate = smartwatchManagerDelegate
        else { return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            guard let self else { return }
            let host = await self.readHostData(from: delegate)
            guard !Task.isCancelled else { return }
            self.latestHostData = host
            self.logForecast(host?.loopState.predictedGlucose ?? [])
            self.triggerWatchStateUpdate(triggeredBy: "Host")
        }
    }

    /// Device log only, to check the cone sent against the host's forecasts.
    @MainActor
    private func logForecast(_ curves: [[PredictedGlucoseValue]]) {
        let lines = GarminWatchState.forecastLogLines(curves)
        guard lines != loggedForecast else { return }
        loggedForecast = lines
        lines.forEach { log($0) }
    }

    /// Reads what the watch shows; `nil` when the readings can't be read.
    private func readHostData(from delegate: SmartwatchManagerDelegate) async -> GarminHostData? {
        let samples: [StoredGlucoseSample]
        do {
            samples = try await delegate.smartwatchManager(self, glucoseSamplesSince: GarminHostData.readingsStart())
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
            correctionRange: await delegate.smartwatchManagerCorrectionRange(self),
            glucoseDisplayLimits: await delegate.smartwatchManagerGlucoseDisplayLimits(self)
        )
    }

    /// Garmin Connect's device-selection callback.
    @MainActor
    public func hostDidReceiveURL(_ url: URL) -> Bool {
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.host == "device-select-resp" else { return false }
        parseDevices(for: url)
        return true
    }

    /// Stops sending: the watch apps get nothing more from the host. The delivery state lives on the
    /// main queue, so it is torn down there; `isDeleted` stops retries, late send completions and
    /// state updates from sending anything afterwards.
    public func delete() async {
        await MainActor.run {
            isDeleted = true
            readTask?.cancel()
            readTask = nil
            cancellables.removeAll()
            connectIQ?.unregister(forAllDeviceEvents: self)
            connectIQ?.unregister(forAllAppMessages: self)
            watchApps.removeAll()
            owedDeliveries.removeAll()
            lastBroadcast = nil
            absentApps.removeAll()
            lastSentDataHashes.removeAll()
            forcedStateKeys.removeAll()
        }
        latestHostData = nil
        await smartwatchManagerDelegate?.retractAlert(identifier: Self.connectMobileMissingAlertIdentifier)
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
