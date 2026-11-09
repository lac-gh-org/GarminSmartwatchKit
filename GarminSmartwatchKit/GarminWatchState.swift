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
            lhs.targetGlucose == rhs.targetGlucose
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
    }

    private static func twoPlaces(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

/// Garmin's watch state built only from the host's `SmartwatchStatusSnapshot`,
/// so the Garmin plugin needs nothing from Trio's stores.
public extension GarminWatchState {
    /// What the snapshot doesn't carry: Trio's Garmin display settings.
    struct DisplayOptions: Equatable, Sendable {
        /// `GarminPrimaryAttributeChoice` raw value.
        public var primaryAttributeChoice: String
        /// `GarminSecondaryAttributeChoice` raw value.
        public var secondaryAttributeChoice: String
        /// "dynamic" or "static", the wire format the watchface reads.
        public var glucoseColorScheme: String
        /// The most readings to send, newest included (`GarminWatchface.historyCount`).
        public var historyCount: Int

        public init(primaryAttributeChoice: String, secondaryAttributeChoice: String, glucoseColorScheme: String, historyCount: Int) {
            self.primaryAttributeChoice = primaryAttributeChoice
            self.secondaryAttributeChoice = secondaryAttributeChoice
            self.glucoseColorScheme = glucoseColorScheme
            self.historyCount = historyCount
        }
    }

    /// Newest reading first, like dev's GarminManager: the first entry carries
    /// every value, the others only their time and glucose. Empty without readings.
    static func states(
        from snapshot: SmartwatchStatusSnapshot,
        options: DisplayOptions,
        now: Date = Date()
    ) -> [GarminWatchState] {
        var readings = snapshot.glucoseHistory
        if let latest = snapshot.glucose, !readings.contains(where: { $0.date == latest.date }) {
            readings.append(latest)
        }
        readings.sort { $0.date > $1.date }
        guard let latest = readings.first else { return [] }

        var first = GarminWatchState()
        // When the loop last ran, not when the reading arrived; 31 minutes ago when
        // unknown, so the watch shows the loop as stale rather than as no data yet.
        first.date = milliseconds(snapshot.lastLoopCompleted ?? now.addingTimeInterval(-31 * 60))
        first.glucoseDate = milliseconds(latest.date)
        first.sgv = mgdL(latest.milligramsPerDeciliter)
        first.direction = latest.trend.map(direction) ?? "--"
        first.delta = readings.count > 1
            ? mgdL(latest.milligramsPerDeciliter - readings[1].milligramsPerDeciliter)
            : 0
        first.units_hint = snapshot.displayUnit == .millimolesPerLiter ? "mmol" : "mgdl"
        first.iob = formattedIOB(snapshot.insulinOnBoard ?? 0)
        first.cob = snapshot.carbsOnBoard
        first.tbr = snapshot.therapy.flatMap { $0.tempBasalRate ?? $0.scheduledBasalRate }
        first.isf = snapshot.therapy?.insulinSensitivity.flatMap(mgdL)
        first.eventualBG = snapshot.therapy?.eventualGlucose.flatMap(mgdL)
        first.sensRatio = snapshot.therapy?.sensitivityRatio
        first.targetGlucose = snapshot.therapy?.correctionRange.flatMap { mgdL(($0.lowerBound + $0.upperBound) / 2) }
        first.displayPrimaryAttributeChoice = options.primaryAttributeChoice
        first.displaySecondaryAttributeChoice = options.secondaryAttributeChoice
        first.glucoseColorScheme = options.glucoseColorScheme

        let older = readings.dropFirst().prefix(max(options.historyCount - 1, 0))
        return [first] + older.map { reading in
            var state = GarminWatchState()
            state.date = milliseconds(reading.date)
            state.sgv = mgdL(reading.milligramsPerDeciliter)
            return state
        }
    }

    /// Nightscout direction names, which Garmin's watch apps read.
    static func direction(_ trend: SmartwatchGlucoseTrend) -> String {
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

    private static func mgdL(_ value: Double) -> Int16? {
        guard value.isFinite, abs(value) <= Double(Int16.max) else { return nil }
        return Int16(value.rounded())
    }
}
