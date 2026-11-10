import Foundation
import ConnectIQ
import LoopKit
import Testing

@testable import GarminSmartwatchKit

@Suite("Garmin watch state from what the host returns") struct GarminWatchStateSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let options = GarminWatchState.DisplayOptions(
        primaryAttributeChoice: "cob",
        secondaryAttributeChoice: "tbr",
        glucoseColorScheme: "static",
        historyCount: GarminWatchface.trio.historyCount
    )

    private func reading(minutesAgo: Double, _ mgdL: Double, _ trend: GlucoseTrend? = .flat) -> StoredGlucoseSample {
        StoredGlucoseSample(
            startDate: now.addingTimeInterval(-minutesAgo * 60),
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdL),
            trend: trend
        )
    }

    private func milliseconds(minutesAgo: Double) -> UInt64 {
        UInt64(now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1000)
    }

    private func mgdL(_ value: Double) -> LoopQuantity {
        LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: value)
    }

    private func hostData(
        history: [StoredGlucoseSample],
        unit: LoopUnit = .millimolesPerLiter,
        lastLoop: Date? = nil,
        eventualGlucose: LoopQuantity? = nil,
        sensitivityRatio: Double? = nil,
        scheduledBasalRate: Double? = nil,
        tempBasalRate: Double? = nil,
        insulinSensitivity: LoopQuantity? = nil,
        correctionRange: ClosedRange<LoopQuantity>? = nil
    ) -> GarminHostData {
        GarminHostData(
            displayUnit: unit,
            glucoseSamples: history,
            loopState: SmartwatchLoopState(
                lastLoopCompleted: lastLoop ?? now.addingTimeInterval(-120),
                isClosedLoop: true,
                insulinOnBoard: InsulinValue(startDate: now, value: 1.234),
                carbsOnBoard: CarbValue(startDate: now, endDate: now, value: 22),
                eventualGlucose: eventualGlucose,
                sensitivityRatio: sensitivityRatio
            ),
            scheduledBasalRate: scheduledBasalRate.map { LoopQuantity(unit: .internationalUnitsPerHour, doubleValue: $0) },
            tempBasal: tempBasalRate.map {
                DoseEntry(type: .tempBasal, startDate: now, endDate: now.addingTimeInterval(1800), value: $0, unit: .unitsPerHour, decisionId: nil)
            },
            insulinSensitivity: insulinSensitivity,
            correctionRange: correctionRange
        )
    }

    @Test("The first entry carries every value") func firstEntry() {
        let history = [reading(minutesAgo: 10, 100), reading(minutesAgo: 5, 104), reading(minutesAgo: 0, 110, .up)]
        let states = GarminWatchState.states(from: hostData(
            history: history,
            eventualGlucose: mgdL(120.6),
            sensitivityRatio: 1.1,
            scheduledBasalRate: 0.8,
            tempBasalRate: 0.35,
            insulinSensitivity: LoopQuantity(unit: .milligramsPerDeciliterPerInternationalUnit, doubleValue: 54.4),
            correctionRange: mgdL(100) ... mgdL(110)
        ), options: options, now: now)

        #expect(states.count == 1, "no history for the Trio watchface")
        let first = try! #require(states.first)
        #expect(first.sgv == 110)
        #expect(first.delta == 6)
        #expect(first.direction == "FortyFiveUp")
        #expect(first.glucoseDate == milliseconds(minutesAgo: 0))
        #expect(first.date == milliseconds(minutesAgo: 2), "when the loop last ran")
        #expect(first.units_hint == "mmol")
        #expect(first.iob == 1.2)
        #expect(first.cob == 22)
        #expect(first.tbr == 0.35)
        #expect(first.isf == 54)
        #expect(first.eventualBG == 121)
        #expect(first.sensRatio == 1.1)
        #expect(first.targetGlucose == 105)
        #expect(first.displayPrimaryAttributeChoice == "cob")
        #expect(first.displaySecondaryAttributeChoice == "tbr")
        #expect(first.glucoseColorScheme == "static")
    }

    @Test("Without a temp basal, the scheduled basal") func scheduledBasal() {
        let states = GarminWatchState.states(
            from: hostData(history: [reading(minutesAgo: 0, 100)], unit: .milligramsPerDeciliter, scheduledBasalRate: 0.8),
            options: options,
            now: now
        )
        #expect(states.first?.tbr == 0.8)
        #expect(states.first?.units_hint == "mgdl")
        #expect(states.first?.delta == 0, "one reading: no delta")
    }

    @Test("SwissAlpine and the complication app get up to 24 readings, newest first") func history() {
        var withHistory = options
        withHistory.historyCount = GarminWatchface.swissalpine.historyCount
        let history = (0 ..< 36).reversed().map { reading(minutesAgo: Double($0) * 5, 100 + Double($0)) }
        let states = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now)

        #expect(states.count == 24)
        #expect(states[0].sgv == 100)
        #expect(states[1].sgv == 101)
        #expect(states[1].date == milliseconds(minutesAgo: 5), "older entries carry the reading's time")
        #expect(states[1].iob == nil, "older entries carry only time and glucose")
        #expect(states[23].sgv == 123)
    }

    @Test("The Trio app gets every reading in the host's 3 h, up to 48") func trioAppHistory() {
        var withHistory = options
        withHistory.historyCount = GarminWatchface.trioApp.historyCount
        let history = (0 ..< 37).reversed().map { reading(minutesAgo: Double($0) * 5, 100 + Double($0)) }
        let states = GarminWatchState.states(from: snapshot(history: history), options: withHistory, now: now)

        #expect(states.count == 37, "fewer readings than 48: all of them")
        #expect(states[0].sgv == 100)
        #expect(states[36].sgv == 136)
        #expect(states[36].date == milliseconds(minutesAgo: 180))
    }

    @Test("Trio's watchface gets only the newest reading") func noHistory() {
        let history = (0 ..< 12).reversed().map { reading(minutesAgo: Double($0) * 5, 100 + Double($0)) }
        let states = GarminWatchState.states(from: snapshot(history: history), options: options, now: now)
        #expect(states.count == 1)
    }

    @Test("No loop yet: 31 minutes ago, so the watch shows it as stale") func noLoop() {
        var host = hostData(history: [reading(minutesAgo: 0, 100)])
        host.loopState.lastLoopCompleted = nil
        let states = GarminWatchState.states(from: host, options: options, now: now)
        #expect(states.first?.date == milliseconds(minutesAgo: 31))
    }

    @Test("No readings: nothing to send") func noReadings() {
        let empty = hostData(history: [], unit: .milligramsPerDeciliter)
        #expect(GarminWatchState.states(from: empty, options: options, now: now).isEmpty)
    }

    @Test("Values a host lacks stay out: no sensitivity ratio, no therapy values") func missingValues() {
        let latest = reading(minutesAgo: 0, 98, nil)
        let states = GarminWatchState.states(from: hostData(history: [latest], unit: .milligramsPerDeciliter), options: options, now: now)
        #expect(states.first?.sgv == 98)
        #expect(states.first?.direction == "--")
        #expect(states.first?.sensRatio == nil)
        #expect(states.first?.tbr == nil)
        #expect(states.first?.isf == nil)
        #expect(states.first?.eventualBG == nil)
        #expect(states.first?.targetGlucose == nil)
    }

    @Test("Values in mmol/L are sent in mg/dL") func mmolValues() {
        let mmol = { (value: Double) in LoopQuantity(unit: .millimolesPerLiter, doubleValue: value) }
        let latest = StoredGlucoseSample(startDate: now, quantity: mmol(5.5), trend: .flat)
        let host = hostData(
            history: [latest],
            eventualGlucose: mmol(6.7),
            insulinSensitivity: LoopQuantity(unit: .millimolesPerLiterPerInternationalUnit, doubleValue: 3),
            correctionRange: mmol(5.5) ... mmol(6.1)
        )
        let first = GarminWatchState.states(from: host, options: options, now: now).first
        #expect(first?.sgv == 99)
        #expect(first?.eventualBG == 121)
        #expect(first?.isf == 54)
        #expect(first?.targetGlucose == 104, "5.8 mmol/L is 104.49 mg/dL")
    }

    @Test("Trends map to Nightscout directions; small IOB stays visible") func directionsAndIOB() {
        #expect(GlucoseTrend.allCases.map(GarminWatchState.direction) == [
            "DoubleUp", "SingleUp", "FortyFiveUp", "Flat", "FortyFiveDown", "SingleDown", "DoubleDown"
        ])
        #expect(GarminWatchState.formattedIOB(0.04) == 0.1)
        #expect(GarminWatchState.formattedIOB(-0.04) == -0.1)
        #expect(GarminWatchState.formattedIOB(0) == 0)
        #expect(GarminWatchState.formattedIOB(2.46) == 2.5)
    }
}

@Suite("Garmin settings and devices") struct GarminStateTests {
    @Test("Settings and devices survive the plugin's raw state") func rawStateRoundTrip() throws {
        let manager = GarminSmartwatchManager()
        var settings = GarminWatchSettings()
        settings.watchface = .swissalpine
        settings.datafield = .none
        settings.primaryAttributeChoice = .isf
        settings.secondaryAttributeChoice = .eventualBG
        settings.glucoseColorScheme = .dynamicColor
        settings.isWatchfaceDataEnabled = false
        manager.settings = settings

        let restored = try #require(GarminSmartwatchManager(rawState: manager.rawState))
        #expect(restored.settings == settings)
        #expect(restored.devices.isEmpty)
    }

    @Test("Saved devices come back") func devices() throws {
        let device = GarminDevice(iqDevice: IQDevice(id: UUID(), modelName: "fenix 8", friendlyName: "My fenix"))
        let state: [String: Any] = ["devices": try JSONEncoder().encode([device])]
        let restored = try #require(GarminSmartwatchManager(rawState: state))
        #expect(restored.devices.map(GarminDevice.init) == [device])
    }

    @Test("Before the host data is read there is nothing to send") func noHostData() {
        #expect(GarminSmartwatchManager().watchStateData() == nil)
    }
}

@Suite("Garmin device alerts") struct GarminDeviceAlertTests {
    private final class Host: SmartwatchManagerDelegate {
        var issued: [Alert] = []
        var retracted: [Alert.Identifier] = []
        var logs: [String] = []
        func smartwatchManagerDidUpdateState(_: SmartwatchManager) {}
        func smartwatchManagerWantsDeletion(_: SmartwatchManager) async {}
        func deviceManager(_: DeviceManager, logEventForDeviceIdentifier _: String?, type _: DeviceLogEntryType, message: String, completion _: ((Error?) -> Void)?) {
            logs.append(message)
        }
        func issueAlert(_ alert: Alert) async { issued.append(alert) }
        func retractAlert(identifier: Alert.Identifier) async { retracted.append(identifier) }
        func doesIssuedAlertExist(identifier _: Alert.Identifier) async throws -> Bool { false }
        func lookupAllUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
        func lookupAllUnacknowledgedUnretracted(managerIdentifier _: String) async throws -> [PersistedAlert] { [] }
        func recordRetractedAlert(_: Alert, at _: Date) async throws {}
        func smartwatchManagerGlucoseDisplayUnit(_: SmartwatchManager) async -> LoopUnit { .milligramsPerDeciliter }
        func smartwatchManager(_: SmartwatchManager, glucoseSamplesSince _: Date) async throws -> [StoredGlucoseSample] { [] }
        func smartwatchManagerLoopState(_: SmartwatchManager) async -> SmartwatchLoopState {
            SmartwatchLoopState(lastLoopCompleted: nil, isClosedLoop: false)
        }
        func smartwatchManagerScheduledBasalRate(_: SmartwatchManager) async -> LoopQuantity? { nil }
        func smartwatchManagerTempBasal(_: SmartwatchManager) async -> DoseEntry? { nil }
        func smartwatchManagerInsulinSensitivity(_: SmartwatchManager) async -> LoopQuantity? { nil }
        func smartwatchManagerCorrectionRange(_: SmartwatchManager) async -> ClosedRange<LoopQuantity>? { nil }
        func smartwatchManagerOverridePresets(_: SmartwatchManager) async -> [TemporaryPreset] { [] }
        func smartwatchManagerActiveOverride(_: SmartwatchManager) async -> TemporaryScheduleOverride? { nil }
        func smartwatchManagerAlertMuteEnd(_: SmartwatchManager) async -> Date? { nil }
        func smartwatchManagerMaximumBolus(_: SmartwatchManager) async -> Double? { nil }
        func smartwatchManagerMaximumCarbEntry(_: SmartwatchManager) async -> Double? { nil }
        func smartwatchManagerSupportedBolusVolumes(_: SmartwatchManager) async -> [Double] { [] }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    @MainActor @Test("Garmin Connect missing raises a time-sensitive host alert; deleting the plugin retracts it") func connectMobileMissing() async {
        let host = Host()
        let manager = GarminSmartwatchManager()
        manager.smartwatchManagerDelegate = host

        manager.needsToInstallConnectMobile()
        await settle()
        #expect(host.issued.map(\.identifier) == [GarminSmartwatchManager.connectMobileMissingAlertIdentifier])
        #expect(host.issued.first?.identifier.managerIdentifier == GarminSmartwatchManager.pluginIdentifier)
        #expect(host.issued.first?.interruptionLevel == .timeSensitive)
        #expect(host.issued.first?.backgroundContent.title == "Garmin Connect isn't installed")

        await manager.delete()
        #expect(host.retracted == [GarminSmartwatchManager.connectMobileMissingAlertIdentifier])
    }
}
