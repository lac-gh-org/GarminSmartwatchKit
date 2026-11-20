//
//  GarminWatchSettings.swift
//  GarminSmartwatchKit
//
//  From Trio's GarminWatchSettings and GarminDevice (Trio contributors, MIT).
//

import ConnectIQ
import Foundation

// MARK: - Display choices

/// Shown next to glucose by the Trio and SwissAlpine watchfaces and datafields.
public enum GarminPrimaryAttributeChoice: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case cob
    case isf
    case sensRatio

    public var displayName: String {
        switch self {
        case .cob: return LocalizedString("COB", comment: "Garmin display choice: carbs on board")
        case .isf: return LocalizedString("ISF", comment: "Garmin display choice: insulin sensitivity")
        case .sensRatio: return LocalizedString("Sens Ratio", comment: "Garmin display choice: sensitivity ratio")
        }
    }
}

/// The second value the watchfaces and datafields show.
public enum GarminSecondaryAttributeChoice: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case tbr
    case eventualBG

    public var displayName: String {
        switch self {
        case .tbr: return LocalizedString("TBR", comment: "Garmin display choice: temp basal rate")
        case .eventualBG: return LocalizedString("evBG", comment: "Garmin display choice: eventual glucose")
        }
    }
}

/// How the watch colours glucose.
public enum GarminGlucoseColorScheme: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    /// The wire format the watch apps read.
    case staticColor = "static"
    case dynamicColor = "dynamic"

    public var displayName: String {
        switch self {
        case .staticColor: return LocalizedString("Static", comment: "Garmin glucose colour scheme: static")
        case .dynamicColor: return LocalizedString("Dynamic", comment: "Garmin glucose colour scheme: dynamic")
        }
    }
}

/// Which readings the watch's time in range counts.
public enum GarminTimeInRangePeriod: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    /// Since midnight in the phone's time zone.
    case today
    case past24Hours

    public var displayName: String {
        switch self {
        case .past24Hours: return LocalizedString("Past 24 Hours", comment: "Garmin time in range: the past 24 hours")
        case .today: return LocalizedString("Today", comment: "Garmin time in range: since midnight")
        }
    }

    /// The oldest reading counted.
    public func start(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .past24Hours: return now.addingTimeInterval(-24 * 60 * 60)
        case .today: return calendar.startOfDay(for: now)
        }
    }
}

/// The glucose range the watch's time in range counts as in range, as Trio's home
/// stats panel: a lower limit of 70 (Standard) or 63 (Extended) mg/dL, Trio's
/// `TimeInRangeType.bottomThreshold`, up to a fixed 180.
public enum GarminTimeInRangeTarget: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case standard
    case extended

    /// In mg/dL, both ends in range.
    public var bounds: ClosedRange<Double> {
        switch self {
        case .standard: return 70 ... 180
        case .extended: return 63 ... 180
        }
    }

    /// "Standard (70–180 mg/dL)", or with "3.9–10.0 mmol/L" for a host that shows mmol/L.
    public func displayName(isMillimolesPerLiter: Bool) -> String {
        if isMillimolesPerLiter {
            switch self {
            case .standard: return LocalizedString("Standard (3.9–10.0 mmol/L)", comment: "Garmin time in range: 70–180 mg/dL in mmol/L")
            case .extended: return LocalizedString("Extended (3.5–10.0 mmol/L)", comment: "Garmin time in range: 63–180 mg/dL in mmol/L")
            }
        }
        switch self {
        case .standard: return LocalizedString("Standard (70–180 mg/dL)", comment: "Garmin time in range: Trio's standard lower limit")
        case .extended: return LocalizedString("Extended (63–180 mg/dL)", comment: "Garmin time in range: Trio's extended lower limit")
        }
    }
}

// MARK: - Watch apps

/// The optional parts of the payload a watch app reads. Each app gets only those it
/// reads, and the settings show only those the chosen apps read. Glucose, trend,
/// IOB, COB, basal and the other values every app shows always go.
public struct GarminPayloadContent: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The Primary and Secondary Value choices.
    public static let attributes = GarminPayloadContent(rawValue: 1 << 0)
    /// The Glucose Colors choice.
    public static let colorScheme = GarminPayloadContent(rawValue: 1 << 1)
    /// The forecast cone.
    public static let forecast = GarminPayloadContent(rawValue: 1 << 2)
    /// The time in range.
    public static let timeInRange = GarminPayloadContent(rawValue: 1 << 3)

    public static let all: GarminPayloadContent = [.attributes, .colorScheme, .forecast, .timeInRange]
}

/// The Connect IQ watch apps that take the watchface slot.
public enum GarminWatchface: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case trio
    case swissalpine
    /// Not a watchface but a Connect IQ watch app that republishes the payload as
    /// complications, so any watchface with complication slots can show the data.
    case complication
    /// Not a watchface but the sideloaded WatchAID watch app
    /// (lac-gh-org/GarminSmartwatchApp, working name): one app for Trio and Loop,
    /// with a graph and a Glance.
    case watchAID

    public var displayName: String {
        switch self {
        case .trio: return LocalizedString("Trio", comment: "Garmin watchface: Trio")
        case .swissalpine: return LocalizedString("Swissalpine", comment: "Garmin watchface: SwissAlpine")
        case .complication: return LocalizedString("Complication", comment: "Garmin watch app: complications")
        case .watchAID: return LocalizedString("WatchAID", comment: "Garmin watch app: WatchAID, for Trio and Loop")
        }
    }

    /// The Connect IQ store apps (live builds); WatchAID is sideloaded.
    public var watchfaceUUID: UUID? {
        switch self {
        case .trio: return UUID(uuidString: "7a121867-140e-41ba-9982-2e82e2aa6579")
        case .swissalpine: return UUID(uuidString: "4cea4efd-4aaf-4db4-8891-ef36dde14303")
        case .complication: return UUID(uuidString: "0986fd19-604b-4bcb-a931-6f8621738682")
        case .watchAID: return UUID(uuidString: "fbab5ed8-4aa6-4f53-8fb5-732660aa2e34")
        }
    }

    /// What the watch app reads beyond the values every app shows. Trio's help text
    /// has both watchfaces show the Primary and Secondary Value; the Complication
    /// app reads both and Glucose Colors. WatchAID shows its own values, the forecast
    /// and the time in range.
    public var payloadContent: GarminPayloadContent {
        switch self {
        case .trio, .swissalpine, .complication: return [.attributes, .colorScheme]
        case .watchAID: return [.colorScheme, .forecast, .timeInRange]
        }
    }

    /// How far back the readings the watch app gets reach, measured from the newest
    /// reading; 0 sends the newest reading only. Time rather than a count, so it
    /// means the same with any CGM. The plugin sends readings from only the last
    /// `GarminHostData.historyInterval` (3 h), so a longer span gets no more than
    /// that.
    public var historySpan: TimeInterval {
        switch self {
        case .trio: return 0
        case .swissalpine, .complication: return 2 * 60 * 60
        // Its graph shows all the host has: 4 h is more than the host's 3 h, so it
        // gets every reading.
        case .watchAID: return 4 * 60 * 60
        }
    }

    /// The least time between two readings the watch app gets. With 5 minutes a
    /// 1-minute CGM sends every 5th reading, so these apps get as many readings, as
    /// far apart, as with a 5-minute CGM.
    public var historySpacing: TimeInterval {
        switch self {
        case .trio, .swissalpine, .complication, .watchAID: return 5 * 60
        }
    }
}

/// The Connect IQ datafields.
public enum GarminDatafield: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case trio
    case swissalpine
    case none

    public var displayName: String {
        switch self {
        case .trio: return LocalizedString("Trio", comment: "Garmin datafield: Trio")
        case .swissalpine: return LocalizedString("Swissalpine", comment: "Garmin datafield: SwissAlpine")
        case .none: return LocalizedString("None", comment: "Garmin datafield: none")
        }
    }

    /// The Connect IQ store apps (live builds).
    public var datafieldUUID: UUID? {
        switch self {
        case .trio: return UUID(uuidString: "3d9b6528-8c84-459a-bbab-989b5f001ebd")
        case .swissalpine: return UUID(uuidString: "dec5292a-74b0-41bc-8e45-cd93f1d5e137")
        case .none: return nil
        }
    }

    /// What the datafield reads beyond the values every app shows: both show the
    /// Primary and Secondary Value, and neither reads Glucose Colors.
    public var payloadContent: GarminPayloadContent {
        switch self {
        case .trio, .swissalpine: return .attributes
        case .none: return []
        }
    }
}

// MARK: - Settings

/// The plugin's settings, saved in its `rawState`.
public struct GarminWatchSettings: Codable, Hashable, Sendable {
    public var watchface: GarminWatchface = .trio
    public var datafield: GarminDatafield = .trio
    public var primaryAttributeChoice: GarminPrimaryAttributeChoice = .cob
    public var secondaryAttributeChoice: GarminSecondaryAttributeChoice = .tbr
    public var glucoseColorScheme: GarminGlucoseColorScheme = .staticColor
    /// Off while the user switches watchfaces on the watch, or uses only a datafield.
    public var isWatchfaceDataEnabled: Bool = true
    /// On by default, as Trio's home stats panel shows time in range by default.
    public var isTimeInRangeEnabled: Bool = true
    /// Today by default, as Trio's home stats panel.
    public var timeInRangePeriod: GarminTimeInRangePeriod = .today
    public var timeInRangeTarget: GarminTimeInRangeTarget = .standard

    public init() {}

    /// What the chosen watchface and datafield read between them. The watchface
    /// counts even while Send to Watchface is off, as that is often only while the
    /// user switches watchfaces on the watch.
    public var payloadContent: GarminPayloadContent {
        watchface.payloadContent.union(datafield.payloadContent)
    }

    /// Each setting missing from what was saved (one added since) or no longer
    /// known (a choice removed since) takes its default, rather than all of them
    /// going back to theirs.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, or fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let defaults = GarminWatchSettings()
        watchface = value(.watchface, or: defaults.watchface)
        datafield = value(.datafield, or: defaults.datafield)
        primaryAttributeChoice = value(.primaryAttributeChoice, or: defaults.primaryAttributeChoice)
        secondaryAttributeChoice = value(.secondaryAttributeChoice, or: defaults.secondaryAttributeChoice)
        glucoseColorScheme = value(.glucoseColorScheme, or: defaults.glucoseColorScheme)
        isWatchfaceDataEnabled = value(.isWatchfaceDataEnabled, or: defaults.isWatchfaceDataEnabled)
        isTimeInRangeEnabled = value(.isTimeInRangeEnabled, or: defaults.isTimeInRangeEnabled)
        timeInRangePeriod = value(.timeInRangePeriod, or: defaults.timeInRangePeriod)
        timeInRangeTarget = value(.timeInRangeTarget, or: defaults.timeInRangeTarget)
    }

    private enum CodingKeys: String, CodingKey {
        case watchface
        case datafield
        case primaryAttributeChoice
        case secondaryAttributeChoice
        case glucoseColorScheme
        case isWatchfaceDataEnabled
        case isTimeInRangeEnabled
        case timeInRangePeriod
        case timeInRangeTarget
    }
}

// MARK: - Devices

/// A Connect IQ device as saved in the plugin's `rawState`.
public struct GarminDevice: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let modelName: String
    public let friendlyName: String

    public init(iqDevice: IQDevice) {
        id = iqDevice.uuid
        modelName = iqDevice.modelName
        friendlyName = iqDevice.friendlyName
    }

    public var iqDevice: IQDevice {
        IQDevice(id: id, modelName: modelName, friendlyName: friendlyName)
    }
}
