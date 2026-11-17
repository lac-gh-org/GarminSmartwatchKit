//
//  GarminWatchState.swift
//  GarminSmartwatchKit
//
//  From Trio's GarminWatchState (created by Cengiz Deniz on 25.01.25; Trio contributors, MIT).
//

import Foundation
import LoopKit

// MARK: - Unified Garmin Watch State

/// Unified watch state structure for both Trio and SwissAlpine watchfaces.
/// Uses the SwissAlpine xDrip+ compatible data format.
/// Sent as an array where the first entry contains all extended data fields.
public struct GarminWatchState: Hashable, Equatable, Sendable, Encodable {
    /// Timestamp of the enacted loop determination in milliseconds since Unix epoch
    /// Shows when the loop actually executed, used to indicate loop staleness
    var date: UInt64?

    /// Timestamp of the glucose reading in milliseconds since Unix epoch
    /// Used by watchface to determine glucose freshness for coloring logic
    var glucoseDate: UInt64?

    /// Sensor glucose value in raw mg/dL (no unit conversion applied)
    var sgv: Int16?

    /// Change in glucose since previous reading as an integer
    var delta: Int16?

    /// Glucose trend direction (e.g., "Flat", "FortyFiveUp", "SingleUp")
    var direction: String?

    /// Signal noise level (optional, typically not used)
    var noise: Double?

    /// Unit hint for the watchface ("mgdl" or "mmol")
    var units_hint: String?

    /// Insulin on board as a decimal value
    var iob: Double?

    /// Current temp basal rate in U/hr
    var tbr: Double?

    /// Carbs on board as a decimal value
    var cob: Double?

    /// Predicted eventual blood glucose
    var eventualBG: Int16?

    /// Current insulin sensitivity factor as an integer (only in first array entry)
    var isf: Int16?

    /// Sensitivity ratio
    var sensRatio: Double?

    // MARK: - Display Configuration Fields

    /// Primary attribute to display
    /// Options: "cob", "isf", or "sensRatio"
    var displayPrimaryAttributeChoice: String?

    /// secondary attribute to display
    /// Options: "tbr" or "eventualBG"
    var displaySecondaryAttributeChoice: String?

    /// Trio color scheme for BG curve currently used
    /// Options: "dynamic" or "static"
    var glucoseColorScheme: String?

    /// Scheduled Profile target currently active
    var targetGlucose: Int16?

    /// The host app's name ("Trio", "Loop"), for the watch to show; only in the
    /// first entry. For display only: a watch app takes what it can do from the
    /// values it gets, never from this name.
    var host: String?

    /// Time of the forecast cone's first value in milliseconds since Unix epoch
    /// (only in the first array entry). The values are 5 minutes apart.
    var forecastDate: UInt64?

    /// The forecast cone's lower edge in raw mg/dL, one value per 5 minutes from
    /// `forecastDate`, at most 4 hours. Equal to `forecastHigh` for Loop's one curve.
    var forecastLow: [Int16]?

    /// The forecast cone's upper edge in raw mg/dL, as `forecastLow`.
    var forecastHigh: [Int16]?

    /// Time in range, in whole percent adding up to 100: the readings below, in and
    /// above the range (`GarminTimeInRangeTarget`) over the chosen period
    /// (`GarminTimeInRangePeriod`). Only in the first entry, and all three or none:
    /// none when it's off or the period has no readings.
    var tirLow: Int?
    var tirInRange: Int?
    var tirHigh: Int?

    public static func == (lhs: GarminWatchState, rhs: GarminWatchState) -> Bool {
        lhs.date == rhs.date &&
            lhs.glucoseDate == rhs.glucoseDate &&
            lhs.sgv == rhs.sgv &&
            lhs.delta == rhs.delta &&
            lhs.direction == rhs.direction &&
            lhs.noise == rhs.noise &&
            lhs.units_hint == rhs.units_hint &&
            lhs.iob == rhs.iob &&
            lhs.tbr == rhs.tbr &&
            lhs.cob == rhs.cob &&
            lhs.eventualBG == rhs.eventualBG &&
            lhs.isf == rhs.isf &&
            lhs.sensRatio == rhs.sensRatio &&
            lhs.displayPrimaryAttributeChoice == rhs.displayPrimaryAttributeChoice &&
            lhs.displaySecondaryAttributeChoice == rhs.displaySecondaryAttributeChoice &&
            lhs.glucoseColorScheme == rhs.glucoseColorScheme &&
            lhs.targetGlucose == rhs.targetGlucose &&
            lhs.host == rhs.host &&
            lhs.forecastDate == rhs.forecastDate &&
            lhs.forecastLow == rhs.forecastLow &&
            lhs.forecastHigh == rhs.forecastHigh &&
            lhs.tirLow == rhs.tirLow &&
            lhs.tirInRange == rhs.tirInRange &&
            lhs.tirHigh == rhs.tirHigh
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(glucoseDate)
        hasher.combine(sgv)
        hasher.combine(delta)
        hasher.combine(direction)
        hasher.combine(noise)
        hasher.combine(units_hint)
        hasher.combine(iob)
        hasher.combine(tbr)
        hasher.combine(cob)
        hasher.combine(eventualBG)
        hasher.combine(isf)
        hasher.combine(sensRatio)
        hasher.combine(displayPrimaryAttributeChoice)
        hasher.combine(displaySecondaryAttributeChoice)
        hasher.combine(glucoseColorScheme)
        hasher.combine(targetGlucose)
        hasher.combine(host)
        hasher.combine(forecastDate)
        hasher.combine(forecastLow)
        hasher.combine(forecastHigh)
        hasher.combine(tirLow)
        hasher.combine(tirInRange)
        hasher.combine(tirHigh)
    }

    enum CodingKeys: String, CodingKey {
        case date
        case glucoseDate
        case sgv
        case delta
        case direction
        case noise
        case units_hint
        case iob
        case tbr
        case cob
        case eventualBG
        case isf
        case sensRatio
        case displayPrimaryAttributeChoice
        case displaySecondaryAttributeChoice
        case glucoseColorScheme
        case targetGlucose
        case host
        case forecastDate
        case forecastLow
        case forecastHigh
        case tirLow
        case tirInRange
        case tirHigh
    }

    /// Custom encoding that excludes nil values from the JSON output
    /// Double values are rounded to 2 decimal places to prevent floating point artifacts
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(glucoseDate, forKey: .glucoseDate)
        try container.encodeIfPresent(sgv, forKey: .sgv)
        try container.encodeIfPresent(delta, forKey: .delta)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(noise, forKey: .noise)
        try container.encodeIfPresent(units_hint, forKey: .units_hint)
        // Round Double values to 2 decimal places to prevent floating point artifacts like "0.5600000000000001"
        try container.encodeIfPresent(iob.map(Self.twoPlaces), forKey: .iob)
        try container.encodeIfPresent(tbr.map(Self.twoPlaces), forKey: .tbr)
        try container.encodeIfPresent(cob, forKey: .cob)
        try container.encodeIfPresent(eventualBG, forKey: .eventualBG)
        try container.encodeIfPresent(isf, forKey: .isf)
        try container.encodeIfPresent(sensRatio.map(Self.twoPlaces), forKey: .sensRatio)
        try container.encodeIfPresent(displayPrimaryAttributeChoice, forKey: .displayPrimaryAttributeChoice)
        try container.encodeIfPresent(displaySecondaryAttributeChoice, forKey: .displaySecondaryAttributeChoice)
        try container.encodeIfPresent(glucoseColorScheme, forKey: .glucoseColorScheme)
        try container.encodeIfPresent(targetGlucose, forKey: .targetGlucose)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(forecastDate, forKey: .forecastDate)
        try container.encodeIfPresent(forecastLow, forKey: .forecastLow)
        try container.encodeIfPresent(forecastHigh, forKey: .forecastHigh)
        try container.encodeIfPresent(tirLow, forKey: .tirLow)
        try container.encodeIfPresent(tirInRange, forKey: .tirInRange)
        try container.encodeIfPresent(tirHigh, forKey: .tirHigh)
    }

    private static func twoPlaces(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

/// What the plugin reads from the host for the watch state: the host's Loop types,
/// as the delegate returns them.
public struct GarminHostData {
    public var displayUnit: LoopUnit
    /// Stored readings, in any order, including user-entered and display-only ones.
    public var glucoseSamples: [StoredGlucoseSample]
    public var loopState: SmartwatchLoopState
    public var scheduledBasalRate: LoopQuantity?
    public var tempBasal: DoseEntry?
    public var insulinSensitivity: LoopQuantity?
    public var correctionRange: ClosedRange<LoopQuantity>?
    /// The host's low and high glucose limits, for display only (never for alarms).
    /// Read but not sent to the watch yet: no Garmin watch app uses them so far.
    public var glucoseDisplayLimits: ClosedRange<LoopQuantity>?

    public init(
        displayUnit: LoopUnit,
        glucoseSamples: [StoredGlucoseSample],
        loopState: SmartwatchLoopState,
        scheduledBasalRate: LoopQuantity? = nil,
        tempBasal: DoseEntry? = nil,
        insulinSensitivity: LoopQuantity? = nil,
        correctionRange: ClosedRange<LoopQuantity>? = nil,
        glucoseDisplayLimits: ClosedRange<LoopQuantity>? = nil
    ) {
        self.displayUnit = displayUnit
        self.glucoseSamples = glucoseSamples
        self.loopState = loopState
        self.scheduledBasalRate = scheduledBasalRate
        self.tempBasal = tempBasal
        self.insulinSensitivity = insulinSensitivity
        self.correctionRange = correctionRange
        self.glucoseDisplayLimits = glucoseDisplayLimits
    }

    /// How far back the readings the watch shows reach.
    public static let historyInterval: TimeInterval = 3 * 60 * 60

    /// How far back to read: far enough for the time in range of either period,
    /// whichever is chosen, so changing the setting needs no new read. Today can
    /// reach back 25 hours, on the day the clocks go back.
    public static func readingsStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        GarminTimeInRangePeriod.allCases.map { $0.start(now: now, calendar: calendar) }
            .reduce(now.addingTimeInterval(-historyInterval), min)
    }
}

/// Garmin's watch state built only from what the host's delegate returns,
/// so the Garmin plugin needs nothing from Trio's stores.
public extension GarminWatchState {
    /// What the host doesn't carry: Trio's Garmin display settings.
    struct DisplayOptions: Equatable, Sendable {
        /// `GarminPrimaryAttributeChoice` raw value.
        public var primaryAttributeChoice: String
        /// `GarminSecondaryAttributeChoice` raw value.
        public var secondaryAttributeChoice: String
        /// "dynamic" or "static", the wire format the watchface reads.
        public var glucoseColorScheme: String
        /// How far back from the newest reading to send (`GarminWatchface.historySpan`).
        public var historySpan: TimeInterval
        /// The least time between two readings sent (`GarminWatchface.historySpacing`).
        public var historySpacing: TimeInterval
        /// The host app's name for the watch to show (`GarminSmartwatchManager.hostName`).
        public var hostName: String?
        /// Which readings the time in range counts; `nil` (off) sends none.
        public var timeInRangePeriod: GarminTimeInRangePeriod?
        /// The range the time in range counts as in range.
        public var timeInRangeTarget: GarminTimeInRangeTarget

        public init(
            primaryAttributeChoice: String,
            secondaryAttributeChoice: String,
            glucoseColorScheme: String,
            historySpan: TimeInterval,
            historySpacing: TimeInterval,
            hostName: String? = nil,
            timeInRangePeriod: GarminTimeInRangePeriod? = nil,
            timeInRangeTarget: GarminTimeInRangeTarget = .standard
        ) {
            self.primaryAttributeChoice = primaryAttributeChoice
            self.secondaryAttributeChoice = secondaryAttributeChoice
            self.glucoseColorScheme = glucoseColorScheme
            self.historySpan = historySpan
            self.historySpacing = historySpacing
            self.hostName = hostName
            self.timeInRangePeriod = timeInRangePeriod
            self.timeInRangeTarget = timeInRangeTarget
        }
    }

    /// How much closer than `historySpacing` two readings may be and both still be
    /// sent: a 5-minute CGM's readings arrive a few seconds early or late.
    static let historySpacingTolerance: TimeInterval = 30

    /// Newest reading first, like dev's GarminManager: the first entry carries
    /// every value, the others only their time and glucose. Empty without readings
    /// in the last `GarminHostData.historyInterval`.
    static func states(
        from host: GarminHostData,
        options: DisplayOptions,
        now: Date = Date(),
        hostIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [GarminWatchState] {
        // The host is read further back for the time in range; everything else
        // shows only the last few hours.
        let allReadings = hostReadings(host.glucoseSamples, hostIdentifier: hostIdentifier)
        let historyStart = now.addingTimeInterval(-GarminHostData.historyInterval)
        let readings = allReadings.filter { $0.startDate >= historyStart }
            .sorted { $0.startDate > $1.startDate }
        guard let latest = readings.first else { return [] }
        let latestGlucose = mgdLValue(latest.quantity)
        let loop = host.loopState

        var first = GarminWatchState()
        // When the loop last ran, not when the reading arrived; 31 minutes ago when
        // unknown, so the watch shows the loop as stale rather than as no data yet.
        first.date = milliseconds(loop.lastLoopCompleted ?? now.addingTimeInterval(-31 * 60))
        first.glucoseDate = milliseconds(latest.startDate)
        first.sgv = mgdL(latestGlucose)
        first.direction = latest.trend.map(direction) ?? "--"
        first.delta = readings.count > 1
            ? mgdL(latestGlucose - mgdLValue(readings[1].quantity))
            : 0
        first.units_hint = host.displayUnit == .millimolesPerLiter ? "mmol" : "mgdl"
        first.iob = formattedIOB(loop.insulinOnBoard?.value ?? 0)
        first.cob = loop.carbsOnBoard?.quantity.doubleValue(for: .gram)
        first.tbr = host.tempBasal?.unitsPerHour ?? host.scheduledBasalRate?.doubleValue(for: .internationalUnitsPerHour)
        first.isf = host.insulinSensitivity.flatMap(mgdLPerUnit).flatMap(mgdL)
        first.eventualBG = loop.eventualGlucose.flatMap { mgdL(mgdLValue($0)) }
        first.sensRatio = loop.sensitivityRatio
        first.targetGlucose = host.correctionRange.flatMap {
            mgdL((mgdLValue($0.lowerBound) + mgdLValue($0.upperBound)) / 2)
        }
        first.displayPrimaryAttributeChoice = options.primaryAttributeChoice
        first.displaySecondaryAttributeChoice = options.secondaryAttributeChoice
        first.glucoseColorScheme = options.glucoseColorScheme
        first.host = options.hostName

        let cone = forecastCone(loop.predictedGlucose)
        if let start = cone.first?.date {
            first.forecastDate = milliseconds(start)
            first.forecastLow = cone.map(\.low)
            first.forecastHigh = cone.map(\.high)
        }

        if let start = options.timeInRangePeriod?.start(now: now),
           let percentages = timeInRange(allReadings.filter { $0.startDate >= start }, bounds: options.timeInRangeTarget.bounds)
        {
            first.tirLow = percentages.low
            first.tirInRange = percentages.inRange
            first.tirHigh = percentages.high
        }

        return [first] + history(after: readings, options: options).map { reading in
            var state = GarminWatchState()
            state.date = milliseconds(reading.startDate)
            state.sgv = mgdL(mgdLValue(reading.quantity))
            return state
        }
    }

    /// How far apart another app's copy of a reading can be from the host's own: as
    /// LoopKit's `GlucoseStore.duplicateTolerance`. Each app's G7 plugin dates a
    /// reading from its own clock (the sensor's age subtracted from when it heard
    /// it), so the two copies differ by a fraction of a second, either way.
    static let sameReadingTolerance: TimeInterval = 2 * 60

    /// The host's own readings, and other apps' except copies of its own. Its own are
    /// those stamped with the app the plugin runs in, as LoopKit stamps its CGM's
    /// (`HKSource.default()`). Loop also takes in every other app's glucose from
    /// Apple Health, Trio's for one: the same reading again, within a second and
    /// without a trend, which gave a delta of 0 and no arrow. So another app's
    /// reading within `sameReadingTolerance` of one of the host's own is left out.
    /// The rest still count: those after the host's newest, so the watch follows
    /// Loop when its CGM stops and another app's readings carry on, and those in the
    /// host's gaps (Loop not running after an update, say), which a day's time in
    /// range needs. A host whose readings don't carry its identifier (Trio's), or
    /// that has only other apps' readings (Loop with glucose from Health), keeps
    /// them all.
    static func hostReadings(_ samples: [StoredGlucoseSample], hostIdentifier: String?) -> [StoredGlucoseSample] {
        guard let hostIdentifier else { return samples }
        let ownDates = samples.filter { $0.provenanceIdentifier == hostIdentifier }.map(\.startDate).sorted()
        guard !ownDates.isEmpty else { return samples }
        return samples.filter { sample in
            sample.provenanceIdentifier == hostIdentifier || !hasReading(near: sample.startDate, in: ownDates)
        }
    }

    /// Whether `sortedDates` holds one within `sameReadingTolerance` of `date`.
    private static func hasReading(near date: Date, in sortedDates: [Date]) -> Bool {
        // The first date not before date - tolerance, by binary search.
        var low = 0
        var high = sortedDates.count
        let earliest = date.addingTimeInterval(-sameReadingTolerance)
        while low < high {
            let middle = (low + high) / 2
            if sortedDates[middle] < earliest { low = middle + 1 } else { high = middle }
        }
        return low < sortedDates.count && sortedDates[low] <= date.addingTimeInterval(sameReadingTolerance)
    }

    /// The readings after the newest to send, newest first: those less than
    /// `historySpan` older than the newest reading, each at least `historySpacing`
    /// (less the tolerance) older than the one sent before it. The delta above still
    /// comes from the reading right after the newest, whether it's sent or not.
    static func history(after readings: [StoredGlucoseSample], options: DisplayOptions) -> [StoredGlucoseSample] {
        guard let latest = readings.first else { return [] }
        var sent: [StoredGlucoseSample] = []
        var lastSent = latest.startDate
        for reading in readings.dropFirst() {
            guard latest.startDate.timeIntervalSince(reading.startDate) < options.historySpan else { break }
            guard lastSent.timeIntervalSince(reading.startDate) >= options.historySpacing - historySpacingTolerance else { continue }
            sent.append(reading)
            lastSent = reading.startDate
        }
        return sent
    }

    /// The share of readings below, in (both ends included) and above `bounds`, in
    /// mg/dL, counted as Trio's home stats panel counts them: by reading, not by
    /// time, from the first reading on. Whole percentages that add up to 100:
    /// rounded, then the largest takes the difference. `nil` without readings.
    static func timeInRange(_ readings: [StoredGlucoseSample], bounds: ClosedRange<Double>) -> (low: Int, inRange: Int, high: Int)? {
        guard !readings.isEmpty else { return nil }
        let values = readings.map { mgdLValue($0.quantity) }
        let counts = [
            values.filter { $0 < bounds.lowerBound }.count,
            values.filter { bounds.contains($0) }.count,
            values.filter { $0 > bounds.upperBound }.count
        ]
        var percentages = counts.map { Int((Double($0) * 100 / Double(values.count)).rounded()) }
        if let largest = counts.indices.max(by: { counts[$0] < counts[$1] }) {
            percentages[largest] += 100 - percentages.reduce(0, +)
        }
        return (low: percentages[0], inRange: percentages[1], high: percentages[2])
    }

    /// Nightscout direction names, which Garmin's watch apps read.
    static func direction(_ trend: GlucoseTrend) -> String {
        switch trend {
        case .upUpUp: return "DoubleUp"
        case .upUp: return "SingleUp"
        case .up: return "FortyFiveUp"
        case .flat: return "Flat"
        case .down: return "FortyFiveDown"
        case .downDown: return "SingleDown"
        case .downDownDown: return "DoubleDown"
        }
    }

    /// The forecast as a cone: for each time step, the lowest and highest value across
    /// the host's forecast curves (`SmartwatchLoopState.predictedGlucose`), in mg/dL,
    /// cut where the shortest curve ends. One curve (Loop) gives its line, low equal
    /// to high; no curves give none. Sent in the first entry as `forecastDate`,
    /// `forecastLow` and `forecastHigh`; watch apps that don't know them ignore them.
    static func forecastCone(_ curves: [[PredictedGlucoseValue]]) -> [(date: Date, low: Int16, high: Int16)] {
        guard let length = curves.map(\.count).min() else { return [] }
        return (0 ..< length).compactMap { index in
            let values = curves.map { mgdLValue($0[index].quantity) }
            guard let low = values.min().flatMap(mgdL), let high = values.max().flatMap(mgdL) else { return nil }
            return (date: curves[0][index].startDate, low: low, high: high)
        }
    }

    /// The debug log lines for the forecast, in whole mg/dL: each curve, then the
    /// cone as sent. None before the loop has run.
    static func forecastLogLines(_ curves: [[PredictedGlucoseValue]]) -> [String] {
        let cone = forecastCone(curves)
        guard let first = cone.first, let last = cone.last else { return [] }
        let dates = ISO8601DateFormatter()
        var lines = curves.enumerated().map { index, curve in
            "Debug Garmin forecast curve \(index + 1) of \(curves.count), \(curve.count) values: "
                + curve.map { mgdL(mgdLValue($0.quantity)).map(String.init) ?? "?" }.joined(separator: ",")
        }
        lines.append(
            "Debug Garmin forecast cone (sent), \(cone.count) values from \(dates.string(from: first.date)) to \(dates.string(from: last.date)), low-high: "
                + cone.map { "\($0.low)-\($0.high)" }.joined(separator: ",")
        )
        return lines
    }

    /// One decimal, and at least 0.1 in size so a small IOB doesn't show as zero.
    static func formattedIOB(_ value: Double) -> Double {
        if value.magnitude < 0.1, value != 0 {
            return value > 0 ? 0.1 : -0.1
        }
        return (value * 10).rounded() / 10
    }

    private static func milliseconds(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970 * 1000)
    }

    private static func mgdLValue(_ quantity: LoopQuantity) -> Double {
        quantity.doubleValue(for: .milligramsPerDeciliter)
    }

    /// The insulin sensitivity in mg/dL per unit. Trio gives it per unit; Loop as its
    /// schedule stores it, in a glucose unit with "per unit" implied. Any other unit
    /// leaves it off: LoopKit's conversion traps on an incompatible unit.
    static func mgdLPerUnit(_ quantity: LoopQuantity) -> Double? {
        if quantity.is(compatibleWith: .milligramsPerDeciliterPerInternationalUnit) {
            return quantity.doubleValue(for: .milligramsPerDeciliterPerInternationalUnit)
        }
        if quantity.is(compatibleWith: .milligramsPerDeciliter) {
            return quantity.doubleValue(for: .milligramsPerDeciliter)
        }
        return nil
    }

    private static func mgdL(_ value: Double) -> Int16? {
        guard value.isFinite, abs(value) <= Double(Int16.max) else { return nil }
        return Int16(value.rounded())
    }
}
