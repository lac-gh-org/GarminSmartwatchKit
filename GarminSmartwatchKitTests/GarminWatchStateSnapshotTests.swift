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
        historySpan: GarminWatchface.trio.historySpan,
        historySpacing: GarminWatchface.trio.historySpacing
    )

    /// What SwissAlpine and the complication app get: 2 h, 5 minutes apart, 24 at most.
    private var withHistory: GarminWatchState.DisplayOptions {
        var options = options
        options.historySpan = GarminWatchface.swissalpine.historySpan
        options.historySpacing = GarminWatchface.swissalpine.historySpacing
        options.maxEntries = GarminWatchface.swissalpine.maxEntries
        return options
    }

    /// Readings every `interval` minutes from `minutes` ago up to now, glucose 100
    /// plus the minutes ago, so a reading's glucose tells its age.
    private func series(every interval: Double, for minutes: Double) -> [StoredGlucoseSample] {
        stride(from: minutes, through: 0, by: -interval).map { reading(minutesAgo: $0, 100 + $0) }
    }

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
                DoseEntry(type: .tempBasal, startDate: now, endDate: now.addingTimeInterval(1800), value: $0, unit: .unitsPerHour)
            },
            insulinSensitivity: insulinSensitivity,
            correctionRange: correctionRange
        )
    }

    @Test("The display limits are read but not sent to the watch yet") func displayLimitsNotSent() {
        let history = [reading(minutesAgo: 5, 104), reading(minutesAgo: 0, 110, .up)]
        var withLimits = hostData(history: history)
        withLimits.glucoseDisplayLimits = mgdL(70)...mgdL(180)
        #expect(withLimits.glucoseDisplayLimits != nil)
        #expect(
            GarminWatchState.states(from: withLimits, options: options, now: now)
                == GarminWatchState.states(from: hostData(history: history), options: options, now: now)
        )
    }

    private func curve(_ values: [Double]) -> [PredictedGlucoseValue] {
        values.enumerated().map { index, value in
            PredictedGlucoseValue(startDate: now.addingTimeInterval(Double(index) * 300), quantity: mgdL(value))
        }
    }

    @Test("The forecast cone spans the curves at each time, up to the shortest") func forecastCone() {
        let cone = GarminWatchState.forecastCone([curve([140, 137, 133]), curve([140, 135]), curve([140, 142, 145])])
        #expect(cone.map(\.low) == [140, 135])
        #expect(cone.map(\.high) == [140, 142])
        #expect(cone.map(\.date) == [now, now.addingTimeInterval(300)])
    }

    @Test("One forecast curve is its own cone; none gives none") func forecastConeOneOrNone() {
        let cone = GarminWatchState.forecastCone([curve([120, 118])])
        #expect(cone.map(\.low) == [120, 118])
        #expect(cone.map(\.high) == [120, 118])
        #expect(GarminWatchState.forecastCone([]).isEmpty)
    }

    @Test("The first entry carries the forecast cone; the others don't") func forecastSent() throws {
        let history = [reading(minutesAgo: 5, 104), reading(minutesAgo: 0, 110, .up)]
        var withForecast = hostData(history: history)
        withForecast.loopState.predictedGlucose = [curve([110, 112, 115]), curve([110, 108])]
        let states = GarminWatchState.states(from: withForecast, options: options, now: now)
        #expect(states[0].forecastDate == UInt64(now.timeIntervalSince1970 * 1000))
        #expect(states[0].forecastLow == [110, 108])
        #expect(states[0].forecastHigh == [110, 112])
        #expect(states.dropFirst().allSatisfy { $0.forecastLow == nil && $0.forecastHigh == nil && $0.forecastDate == nil })

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(states)) as? [[String: Any]])
        #expect(json[0]["forecastLow"] as? [Int] == [110, 108])
        #expect(json[0]["forecastHigh"] as? [Int] == [110, 112])
        #expect(json[0]["forecastDate"] as? UInt64 == states[0].forecastDate)
    }

    @Test("The debug log has each curve, then the cone") func forecastLogLines() {
        let lines = GarminWatchState.forecastLogLines([curve([110.4, 112]), curve([110, 107.6, 104])])
        #expect(lines.count == 3)
        #expect(lines[0] == "Debug Garmin forecast curve 1 of 2, 2 values: 110,112")
        #expect(lines[1] == "Debug Garmin forecast curve 2 of 2, 3 values: 110,108,104")
        #expect(lines[2].hasPrefix("Debug Garmin forecast cone (sent), 2 values from "))
        #expect(lines[2].hasSuffix("low-high: 110-110,108-112"))
        #expect(GarminWatchState.forecastLogLines([]).isEmpty)
    }

    @Test("Without a forecast the keys are left out") func forecastMissing() throws {
        let states = GarminWatchState.states(from: hostData(history: [reading(minutesAgo: 0, 110)]), options: options, now: now)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(states)) as? [[String: Any]])
        #expect(json[0]["forecastLow"] == nil && json[0]["forecastHigh"] == nil && json[0]["forecastDate"] == nil)
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

    @Test("SwissAlpine and the complication app get 2 h of a 5-minute CGM: 24 readings, newest first") func history() {
        let states = GarminWatchState.states(from: hostData(history: series(every: 5, for: 175)), options: withHistory, now: now)

        #expect(states.count == 24, "as many as the 24-reading count sent before")
        #expect(states[0].sgv == 100)
        #expect(states[1].sgv == 105)
        #expect(states[1].date == milliseconds(minutesAgo: 5), "older entries carry the reading's time")
        #expect(states[1].iob == nil, "older entries carry only time and glucose")
        #expect(states[23].date == milliseconds(minutesAgo: 115), "less than 2 h before the newest")
    }

    @Test("A 1-minute CGM sends every 5th reading over the same 2 h; the delta stays the 1-minute one") func oneMinuteCGM() {
        let states = GarminWatchState.states(from: hostData(history: series(every: 1, for: 180)), options: withHistory, now: now)

        #expect(states.count == 24, "as many as a 5-minute CGM")
        #expect(states.dropFirst().map(\.date) == stride(from: 5.0, through: 115, by: 5).map { milliseconds(minutesAgo: $0) as UInt64? })
        #expect(states[0].delta == -1, "from the reading a minute before, not the next one sent")
    }

    @Test("A 2-minute CGM sends readings at least 5 minutes apart") func twoMinuteCGM() {
        let states = GarminWatchState.states(from: hostData(history: series(every: 2, for: 180)), options: withHistory, now: now)

        #expect(states.dropFirst().map(\.date) == stride(from: 6.0, through: 114, by: 6).map { milliseconds(minutesAgo: $0) as UInt64? })
    }

    @Test("A 5-minute CGM a few seconds early or late keeps every reading") func jitter() {
        // Gaps alternate between 4:58 and 5:02.
        let history = (0 ..< 30).map { i in
            reading(minutesAgo: Double(i) * 5 - (i.isMultiple(of: 2) ? 0 : 2.0 / 60), 100 + Double(i))
        }
        let states = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now)

        #expect(states.map(\.sgv) == (0 ..< 24).map { Int16(100 + $0) as Int16? })
    }

    @Test("Readings a little under 5 minutes apart still send no more than 24") func readingsUnderFiveMinutes() {
        // 4:59 apart: a 25th reading falls inside the 2 h.
        let history = (0 ..< 30).map { reading(minutesAgo: Double($0) * (5 - 1.0 / 60), 100 + Double($0)) }
        let states = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now)

        #expect(states.map(\.sgv) == (0 ..< 24).map { Int16(100 + $0) as Int16? }, "SwissAlpine shows a 25th as stale")
    }

    @Test("A gap stays a gap: nothing is filled in") func gap() {
        let history = [0.0, 5, 10, 50, 55].map { reading(minutesAgo: $0, 100 + $0) }
        let states = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now)

        // The first entry's date is the loop's, so compare the older ones.
        #expect(states.dropFirst().map(\.date) == [5.0, 10, 50, 55].map { milliseconds(minutesAgo: $0) as UInt64? })
    }

    @Test("A span beyond the host's 3 h gets every reading the host sent") func historyBeyondInterval() {
        var longer = withHistory
        longer.historySpan = 4 * 60 * 60
        longer.maxEntries = nil
        let states = GarminWatchState.states(from: hostData(history: series(every: 5, for: 180)), options: longer, now: now)

        #expect(states.count == 37)
        #expect(states[36].sgv == 280)
        #expect(states[36].date == milliseconds(minutesAgo: 180))
    }

    @Test("WatchAID gets every reading in the host's 3 h, and only 5 minutes apart from a 1-minute CGM") func watchAIDHistory() {
        var watchAID = options
        watchAID.historySpan = GarminWatchface.watchAID.historySpan
        watchAID.historySpacing = GarminWatchface.watchAID.historySpacing

        let fiveMinute = GarminWatchState.states(from: hostData(history: series(every: 5, for: 180)), options: watchAID, now: now)
        #expect(fiveMinute.count == 37, "all the host's readings")
        #expect(fiveMinute[36].date == milliseconds(minutesAgo: 180))

        let oneMinute = GarminWatchState.states(from: hostData(history: series(every: 1, for: 180)), options: watchAID, now: now)
        #expect(oneMinute.count == 37, "every 5th reading, still back to 3 h")
    }

    @Test("The host's name goes in the first entry only, and is left out when unknown") func hostName() throws {
        var named = withHistory
        named.hostName = "Trio"
        let history = series(every: 5, for: 10)

        let states = GarminWatchState.states(from: hostData(history: history), options: named, now: now)
        #expect(states.first?.host == "Trio")
        #expect(states.dropFirst().allSatisfy { $0.host == nil }, "older entries carry only time and glucose")

        let json = try #require(String(data: JSONEncoder().encode(states), encoding: .utf8))
        #expect(json.contains(#""host":"Trio""#))

        let unnamed = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now)
        let unnamedJSON = try #require(String(data: JSONEncoder().encode(unnamed), encoding: .utf8))
        #expect(!unnamedJSON.contains("host"), "no key when the host has no name")
    }

    @Test("Trio's watchface gets only the newest reading") func noHistory() {
        let history = (0 ..< 12).reversed().map { reading(minutesAgo: Double($0) * 5, 100 + Double($0)) }
        let states = GarminWatchState.states(from: hostData(history: history), options: options, now: now)
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

    private let loop = "com.example.Loop"
    private let trio = "org.example.Trio"

    private func reading(from source: String, minutesAgo: Double, _ mgdL: Double, _ trend: GlucoseTrend?) -> StoredGlucoseSample {
        StoredGlucoseSample(
            provenanceIdentifier: source,
            startDate: now.addingTimeInterval(-minutesAgo * 60),
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdL),
            trend: trend
        )
    }

    @Test("In Loop, Trio's copies from Apple Health are left out: within a second, no trend") func otherAppsCopies() {
        // Each reading twice: Loop's CGM's with its trend, and Trio's without, dated by
        // Trio's own G7 plugin a fraction of a second earlier or later. The newest
        // copy is later, as in the Loop report where the watch showed +0 and no arrow.
        let history = [(10.0, 160.0, -0.3), (5, 155, 0), (0, 150, 0.4)].flatMap { minutesAgo, value, trioLater in
            [reading(from: trio, minutesAgo: minutesAgo - trioLater / 60, value, nil), reading(from: loop, minutesAgo: minutesAgo, value, .down)]
        }
        let states = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now, hostIdentifier: loop)
        #expect(states[0].sgv == 150)
        #expect(states[0].delta == -5, "from Loop's reading 5 minutes before, not Trio's copy")
        #expect(states[0].direction == "FortyFiveDown", "the trend from Loop's CGM")
        #expect(states.dropFirst().map(\.sgv) == [155, 160])
    }

    @Test("Another app's readings after the host's newest still count, as when Loop's CGM stops") func newerOtherReadings() {
        let history = [
            reading(from: loop, minutesAgo: 10, 160, .flat),
            reading(from: trio, minutesAgo: 10, 160, nil),
            reading(from: trio, minutesAgo: 5, 155, nil),
            reading(from: trio, minutesAgo: 0, 150, nil),
        ]
        let readings = GarminWatchState.hostReadings(history, hostIdentifier: loop)
        #expect(readings.map(\.provenanceIdentifier) == [loop, trio, trio])
        #expect(readings.map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) } == [160, 155, 150])

        // A copy up to sameReadingTolerance after the host's newest is the same reading.
        let copy = [reading(from: loop, minutesAgo: 2, 160, .flat), reading(from: trio, minutesAgo: 0.1, 160, nil)]
        #expect(GarminWatchState.hostReadings(copy, hostIdentifier: loop).map(\.provenanceIdentifier) == [loop])
    }

    @Test("Another app's readings fill the host's gaps; only copies of the host's own are left out") func otherReadingsInGaps() {
        // Loop's CGM heard nothing from 60 to 20 minutes ago (not running after an
        // update, say); Trio's copies from Health cover the whole hour.
        let own = [80.0, 60, 15, 10, 5, 0].map { reading(from: loop, minutesAgo: $0, 150, .flat) }
        let trios = stride(from: 80.0, through: 0, by: -5).map { reading(from: trio, minutesAgo: $0 - 0.005, 150, nil) }
        let readings = GarminWatchState.hostReadings(own + trios, hostIdentifier: loop)
        // Trio's in Loop's gap are kept (to the nearest minute); those at Loop's own
        // times are copies, left out.
        let kept = readings.filter { $0.provenanceIdentifier == trio }
            .map { Int((-$0.startDate.timeIntervalSince(now) / 60).rounded()) }.sorted()
        #expect(kept == [20, 25, 30, 35, 40, 45, 50, 55, 65, 70, 75])
        #expect(readings.filter { $0.provenanceIdentifier == loop }.count == own.count)
    }

    @Test("A day's time in range counts Trio's readings where Loop had none") func timeInRangeWithGaps() {
        // Loop's own readings only for the last hour, all in range; Trio's copies for
        // the whole day, high before that: as on a day of Loop TestFlight updates.
        let own = stride(from: 60.0, through: 0, by: -5).map { reading(from: loop, minutesAgo: $0, 120, .flat) }
        let trios = stride(from: 300.0, through: 0, by: -5).map { minutes in
            reading(from: trio, minutesAgo: minutes - 0.005, minutes > 60 ? 220 : 120, nil)
        }
        var withTIR = options
        withTIR.timeInRangePeriod = .past24Hours
        let first = GarminWatchState.states(from: hostData(history: own + trios), options: withTIR, now: now, hostIdentifier: loop)[0]
        // 13 in range (Loop's last hour), 48 high (Trio's 300 down to 65 minutes ago).
        #expect([first.tirLow, first.tirInRange, first.tirHigh] == [0, 21, 79])
    }

    @Test("Readings that aren't the host's own are all kept: Trio's, and Loop's from Health only") func noOwnReadings() {
        let history = [reading(from: trio, minutesAgo: 5, 155, .flat), reading(from: trio, minutesAgo: 0, 150, .flat)]
        #expect(GarminWatchState.hostReadings(history, hostIdentifier: loop) == history)
        #expect(GarminWatchState.hostReadings(history, hostIdentifier: nil) == history)
        // Trio's host stamps none: all carry LoopKit's default.
        let unstamped = series(every: 5, for: 10)
        #expect(GarminWatchState.hostReadings(unstamped, hostIdentifier: trio) == unstamped)
    }

    @Test("Loop's insulin sensitivity, in a glucose unit with per unit implied, is sent as Trio's") func loopInsulinSensitivity() {
        let mgdLHost = hostData(history: [reading(minutesAgo: 0, 100)], insulinSensitivity: mgdL(54.4))
        #expect(GarminWatchState.states(from: mgdLHost, options: options, now: now).first?.isf == 54)

        let mmolHost = hostData(history: [reading(minutesAgo: 0, 100)], insulinSensitivity: LoopQuantity(unit: .millimolesPerLiter, doubleValue: 3))
        #expect(GarminWatchState.states(from: mmolHost, options: options, now: now).first?.isf == 54)
    }

    @Test("An insulin sensitivity in a unit that isn't one is left off, not converted") func otherInsulinSensitivityUnit() {
        let host = hostData(history: [reading(minutesAgo: 0, 100)], insulinSensitivity: LoopQuantity(unit: .gram, doubleValue: 10))
        let first = GarminWatchState.states(from: host, options: options, now: now).first
        #expect(first?.sgv == 100, "the rest is still sent")
        #expect(first?.isf == nil)
    }

    private func percentages(_ readings: [StoredGlucoseSample], _ target: GarminTimeInRangeTarget = .standard) -> [Int]? {
        GarminWatchState.timeInRange(readings, bounds: target.bounds).map { [$0.low, $0.inRange, $0.high] }
    }

    @Test("Time in range counts readings, both ends of the range in range") func timeInRangeBounds() {
        // 62 and 69 low, 70 and 180 in range, 181 high.
        let readings = [62.0, 69, 70, 180, 181].enumerated().map { reading(minutesAgo: Double(20 - 5 * $0.offset), $0.element) }
        #expect(percentages(readings) == [40, 40, 20])
        #expect(percentages(readings, .extended) == [20, 60, 20], "69 is in range from 63")
        #expect(percentages([reading(minutesAgo: 0, 63)], .extended) == [0, 100, 0], "63 itself is in range")
    }

    @Test("Time in range adds up to 100: the largest takes the rounding") func timeInRangeRounding() {
        // 1 of 8 is 12.5%, rounded up twice: 13 + 75 + 13 = 101.
        let eight = [reading(minutesAgo: 70, 60), reading(minutesAgo: 60, 200)] + series(every: 10, for: 50)
        #expect(percentages(eight) == [13, 74, 13])
        // A third each rounds down: 99.
        let three = [reading(minutesAgo: 60, 60), reading(minutesAgo: 30, 100), reading(minutesAgo: 0, 200)]
        #expect(percentages(three)?.reduce(0, +) == 100)
        #expect(percentages(three)?.sorted() == [33, 33, 34])
    }

    @Test("One reading is enough, as just after midnight in Trio; none gives no time in range") func timeInRangeFirstReading() {
        #expect(percentages([reading(minutesAgo: 0, 200)]) == [0, 0, 100])
        #expect(percentages([]) == nil)
    }

    @Test("Time in range covers the period, beyond the 3 h the watch shows; off sends none") func timeInRangeSent() throws {
        // 23 h and 20 h ago: one low, one high; the last hour in range.
        let history = [reading(minutesAgo: 23 * 60, 60), reading(minutesAgo: 20 * 60, 250)] + series(every: 5, for: 60)
        var withTIR = withHistory
        withTIR.timeInRangePeriod = .past24Hours
        let states = GarminWatchState.states(from: hostData(history: history), options: withTIR, now: now)
        // 1 and 1 of 15 are 7% each; 87 + 7 + 7 = 101.
        #expect([states[0].tirLow, states[0].tirInRange, states[0].tirHigh] == [7, 86, 7])
        #expect(states.count == 13, "the readings sent still reach back only 3 h")
        #expect(states.dropFirst().allSatisfy { $0.tirLow == nil && $0.tirInRange == nil && $0.tirHigh == nil })

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(states[0])) as? [String: Any])
        #expect(json["tirLow"] as? Int == 7)
        #expect(json["tirInRange"] as? Int == 86)
        #expect(json["tirHigh"] as? Int == 7)

        let off = GarminWatchState.states(from: hostData(history: history), options: withHistory, now: now)
        #expect(off[0].tirLow == nil && off[0].tirInRange == nil && off[0].tirHigh == nil)
        #expect(off.dropFirst() == states.dropFirst())
    }

    @Test("No reading in the last 3 h: nothing sent, even with a day of older ones") func timeInRangeOnlyOldReadings() {
        var withTIR = options
        withTIR.timeInRangePeriod = .past24Hours
        let old = [reading(minutesAgo: 10 * 60, 100), reading(minutesAgo: 4 * 60, 100)]
        #expect(GarminWatchState.states(from: hostData(history: old), options: withTIR, now: now).isEmpty)
    }

    @Test("Today starts at midnight in the phone's time zone; the read reaches back to the earlier start") func timeInRangePeriods() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 1_800_000_000 is 08:00 UTC.
        #expect(GarminTimeInRangePeriod.today.start(now: now, calendar: utc) == now.addingTimeInterval(-8 * 60 * 60))
        #expect(GarminTimeInRangePeriod.past24Hours.start(now: now, calendar: utc) == now.addingTimeInterval(-24 * 60 * 60))
        #expect(GarminHostData.readingsStart(now: now, calendar: utc) == now.addingTimeInterval(-24 * 60 * 60))
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
        settings.isTimeInRangeEnabled = false
        settings.timeInRangePeriod = .past24Hours
        settings.timeInRangeTarget = .extended
        manager.settings = settings

        let restored = try #require(GarminSmartwatchManager(rawState: manager.rawState))
        #expect(restored.settings == settings)
        #expect(restored.devices.isEmpty)
    }

    @Test("Settings saved before a setting was added keep their values; the new one takes its default") func settingsMissingKeys() throws {
        // As saved by a version without Glucose Colors, Send to Watchface or time in range.
        let saved = Data(#"{"watchface":"swissalpine","datafield":"none","primaryAttributeChoice":"isf","secondaryAttributeChoice":"eventualBG"}"#.utf8)
        let settings = try JSONDecoder().decode(GarminWatchSettings.self, from: saved)
        #expect(settings.watchface == .swissalpine)
        #expect(settings.datafield == GarminDatafield.none)
        #expect(settings.primaryAttributeChoice == .isf)
        #expect(settings.secondaryAttributeChoice == .eventualBG)
        #expect(settings.glucoseColorScheme == .staticColor)
        #expect(settings.isWatchfaceDataEnabled)
        #expect(settings.isTimeInRangeEnabled)
        #expect(settings.timeInRangePeriod == .today)
        #expect(settings.timeInRangeTarget == .standard)
    }

    @Test("A saved choice that no longer exists takes its default; the others keep theirs") func settingsUnknownValue() throws {
        let saved = Data(#"{"watchface":"retired","datafield":"swissalpine","glucoseColorScheme":"dynamic","isWatchfaceDataEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(GarminWatchSettings.self, from: saved)
        #expect(settings.watchface == .trio)
        #expect(settings.datafield == .swissalpine)
        #expect(settings.glucoseColorScheme == .dynamicColor)
        #expect(settings.isWatchfaceDataEnabled == false)
    }

    @Test("Each watch app reads only its own part of the payload; the settings count the chosen watchface and datafield") func payloadContent() {
        for watchface in GarminWatchface.allCases where watchface != .watchAID {
            #expect(watchface.payloadContent == [.attributes, .colorScheme])
        }
        #expect(GarminWatchface.watchAID.payloadContent == [.colorScheme, .forecast, .timeInRange])
        #expect(GarminWatchface.watchAID.statusReply == .always, "WatchAID starts empty when opened")
        #expect(GarminDatafield.trio.payloadContent == .attributes)
        #expect(GarminDatafield.swissalpine.payloadContent == .attributes)
        #expect(GarminDatafield.none.payloadContent.isEmpty)

        var settings = GarminWatchSettings()
        settings.watchface = .complication
        settings.datafield = .none
        #expect(settings.payloadContent == [.attributes, .colorScheme])
        // Send to Watchface off only while switching: the watchface still counts.
        settings.isWatchfaceDataEnabled = false
        #expect(settings.payloadContent == [.attributes, .colorScheme])
        // Only WatchAID reads the forecast and the time in range.
        #expect(settings.payloadContent.isDisjoint(with: [.forecast, .timeInRange]))
        settings.watchface = .watchAID
        settings.datafield = .swissalpine
        #expect(settings.payloadContent == .all)
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
        /// How many times the plugin read the host's glucose, once per host data read.
        var reads = 0
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
        func smartwatchManager(_: SmartwatchManager, glucoseSamplesSince _: Date) async throws -> [StoredGlucoseSample] {
            reads += 1
            return []
        }
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

    @MainActor @Test("A new reading waits for the loop's result, which is read at once; without one the reading goes alone") func readingWaitsForLoop() async {
        let host = Host()
        let manager = GarminSmartwatchManager()
        manager.glucoseWaitForLoop = 0.5
        manager.smartwatchManagerDelegate = host
        await settle()
        let start = host.reads

        manager.hostDataDidChange(.glucose)
        await settle()
        #expect(host.reads == start, "Waiting for the loop's result")
        manager.hostDataDidChange(.loop)
        await settle()
        #expect(host.reads == start + 1, "The loop's result is read at once")
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(host.reads == start + 1, "The reading's wait was cancelled: one read, one message")

        manager.hostDataDidChange(.glucose)
        try? await Task.sleep(nanoseconds: 800_000_000)
        #expect(host.reads == start + 2, "No loop result: the reading is read after the wait")
    }

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
