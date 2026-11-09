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

// MARK: - Watch apps

/// The Connect IQ watch apps that take the watchface slot.
public enum GarminWatchface: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    public var id: String { rawValue }

    case trio
    case swissalpine
    /// Not a watchface but a Connect IQ watch app that republishes the payload as
    /// complications, so any watchface with complication slots can show the data.
    case complication
    /// Not a watchface but a sideloaded Connect IQ watch app with a Glance
    /// (mountrcg/GarminAppTrioPerso): a glucose gauge, a trend graph and IOB.
    case trioApp

    public var displayName: String {
        switch self {
        case .trio: return LocalizedString("Trio", comment: "Garmin watchface: Trio")
        case .swissalpine: return LocalizedString("Swissalpine", comment: "Garmin watchface: SwissAlpine")
        case .complication: return LocalizedString("Complication", comment: "Garmin watch app: complications")
        case .trioApp: return LocalizedString("Trio App", comment: "Garmin watch app: Trio app with glance")
        }
    }

    /// The Connect IQ store apps (live builds); the Trio app is sideloaded.
    public var watchfaceUUID: UUID? {
        switch self {
        case .trio: return UUID(uuidString: "7a121867-140e-41ba-9982-2e82e2aa6579")
        case .swissalpine: return UUID(uuidString: "4cea4efd-4aaf-4db4-8891-ef36dde14303")
        case .complication: return UUID(uuidString: "0986fd19-604b-4bcb-a931-6f8621738682")
        case .trioApp: return UUID(uuidString: "087bee51-ad92-4296-b03b-18f101b5f751")
        }
    }

    /// The most readings the watch app shows, newest included. The host's snapshot
    /// holds only `SmartwatchStatusSnapshot.historyInterval` (3 h) of readings, so
    /// the Trio app's 48 (4 h) get about 36 at most.
    public var historyCount: Int {
        switch self {
        case .trio: return 1
        case .swissalpine, .complication: return 24
        case .trioApp: return 48
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

    public init() {}
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
