//
//  GarminSmartwatchManager+UI.swift
//  GarminSmartwatchKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import GarminSmartwatchKit
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

extension GarminSmartwatchManager: @retroactive SmartwatchManagerUI {
    public static var onboardingImage: UIImage? { UIImage(systemName: "applewatch.side.right") }
    public var smallImage: UIImage? { Self.onboardingImage }

    /// Adding Garmin creates the plugin; devices and watch apps are chosen in its settings.
    @MainActor
    public static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> SetupUIResult<SmartwatchManagerViewController, SmartwatchManagerUI> {
        .createdAndOnboarded(GarminSmartwatchManager())
    }

    @MainActor
    public func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> SmartwatchManagerViewController {
        GarminSettingsNavigationController(manager: self)
    }
}

final class GarminSettingsNavigationController: UINavigationController, SmartwatchManagerOnboarding, CompletionNotifying {
    weak var smartwatchManagerOnboardingDelegate: SmartwatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init(manager: GarminSmartwatchManager) {
        super.init(nibName: nil, bundle: nil)
        let model = GarminSettingsModel(manager: manager)
        let view = GarminSettingsView(model: model) { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        setViewControllers([UIHostingController(rootView: view)], animated: false)
        navigationBar.prefersLargeTitles = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
