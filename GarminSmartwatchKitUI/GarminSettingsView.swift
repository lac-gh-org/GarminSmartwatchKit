//
//  GarminSettingsView.swift
//  GarminSmartwatchKitUI
//
//  The settings from Trio's Garmin screens (Trio contributors, MIT), for the plugin.
//

import Combine
import ConnectIQ
import GarminSmartwatchKit
import SwiftUI

@MainActor
final class GarminSettingsModel: ObservableObject {
    let manager: GarminSmartwatchManager
    @Published private(set) var devices: [IQDevice] = []
    @Published private(set) var isConnectMobileMissing = false
    @Published var settings: GarminWatchSettings {
        didSet { manager.settings = settings }
    }

    private var cancellables = Set<AnyCancellable>()

    init(manager: GarminSmartwatchManager) {
        self.manager = manager
        settings = manager.settings
        refresh()
        manager.stateDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        devices = manager.devices
        isConnectMobileMissing = manager.isConnectMobileMissing
        if settings != manager.settings { settings = manager.settings }
    }

    /// Opens Garmin Connect to choose the watches.
    func addDevices() {
        manager.selectDevices()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func removeDevices(at offsets: IndexSet) {
        var remaining = manager.devices
        remaining.remove(atOffsets: offsets)
        manager.updateDeviceList(remaining)
    }

    #if targetEnvironment(simulator)
        func addSimulatedDevice() {
            manager.updateDeviceList(manager.devices + [GarminSmartwatchManager.MockIQDevice.createSimulated()])
        }
    #endif
}

struct GarminSettingsView: View {
    @ObservedObject var model: GarminSettingsModel
    let allowDebugFeatures: Bool
    let done: () -> Void

    @State private var confirmingRemoval = false
    @State private var confirmingWatchfaceSwitch = false

    var body: some View {
        List {
            Section {
                Text(LocalizedString("Experimental. The chosen Garmin watch apps show glucose, loop status and therapy values. Nothing is sent from the watch.", comment: "Garmin settings: what the plugin does"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.isConnectMobileMissing {
                Section {
                    Text(LocalizedString("Garmin Connect isn't installed. It's needed to choose watches and send to them.", comment: "Garmin settings: Garmin Connect missing"))
                        .foregroundStyle(.red)
                    Button(LocalizedString("Get Garmin Connect", comment: "Garmin settings: open the App Store")) {
                        model.manager.showAppStoreForConnectMobile()
                    }
                }
            }

            devicesSection
            watchAppSection
            displaySection

            Section {
                Button(LocalizedString("Delete Garmin", comment: "Garmin settings: remove the plugin"), role: .destructive) {
                    confirmingRemoval = true
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle(GarminSmartwatchManager.localizedTitle)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LocalizedString("Done", comment: "Garmin settings: close"), action: done)
            }
        }
        .confirmationDialog(LocalizedString("Delete Garmin?", comment: "Garmin settings: confirm removal"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(LocalizedString("Delete", comment: "Garmin settings: confirm removal button"), role: .destructive) {
                Task {
                    await model.manager.delete()
                    done()
                }
            }
        }
        .alert(LocalizedString("Switch the watchface on the watch", comment: "Garmin settings: watchface switch title"), isPresented: $confirmingWatchfaceSwitch) {
            Button(LocalizedString("I've switched it", comment: "Garmin settings: watchface switched")) {
                model.settings.isWatchfaceDataEnabled = true
            }
            Button(LocalizedString("Later", comment: "Garmin settings: switch later"), role: .cancel) {}
        } message: {
            Text(LocalizedString("Sending to the watchface is paused until the new one runs on the watch.", comment: "Garmin settings: watchface switch message"))
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(model.devices, id: \.uuid) { device in
                VStack(alignment: .leading) {
                    Text(device.friendlyName)
                    Text(device.modelName).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: model.removeDevices)
            Button(LocalizedString("Add Garmin Watch", comment: "Garmin settings: choose watches in Garmin Connect"), action: model.addDevices)
            #if targetEnvironment(simulator)
                if allowDebugFeatures {
                    Button(LocalizedString("Add Simulated Watch", comment: "Garmin settings: simulator only"), action: model.addSimulatedDevice)
                }
            #endif
        } header: {
            Text(LocalizedString("Watches", comment: "Garmin settings: devices section"))
        } footer: {
            Text(LocalizedString("Garmin Connect opens to choose the watches. Swipe to remove one.", comment: "Garmin settings: devices footer"))
        }
    }

    private var watchAppSection: some View {
        Section {
            Picker(LocalizedString("Watchface", comment: "Garmin settings: watchface picker"), selection: $model.settings.watchface) {
                ForEach(GarminWatchface.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: model.settings.watchface) { oldValue, newValue in
                guard oldValue != newValue else { return }
                model.settings.isWatchfaceDataEnabled = false
                confirmingWatchfaceSwitch = true
            }
            Toggle(LocalizedString("Send to Watchface", comment: "Garmin settings: watchface data toggle"), isOn: $model.settings.isWatchfaceDataEnabled)
            Picker(LocalizedString("Datafield", comment: "Garmin settings: datafield picker"), selection: $model.settings.datafield) {
                ForEach(GarminDatafield.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text(LocalizedString("Watch Apps", comment: "Garmin settings: watch apps section"))
        } footer: {
            Text(LocalizedString("Turn off Send to Watchface to use only a datafield. Complication is a watch app that puts the values in any watchface's complications. Trio App is a sideloaded watch app with a glance.", comment: "Garmin settings: watch apps footer"))
        }
    }

    private var displaySection: some View {
        Section {
            Picker(LocalizedString("Primary Value", comment: "Garmin settings: primary attribute"), selection: $model.settings.primaryAttributeChoice) {
                ForEach(GarminPrimaryAttributeChoice.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(LocalizedString("Secondary Value", comment: "Garmin settings: secondary attribute"), selection: $model.settings.secondaryAttributeChoice) {
                ForEach(GarminSecondaryAttributeChoice.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(LocalizedString("Glucose Colors", comment: "Garmin settings: glucose colour scheme"), selection: $model.settings.glucoseColorScheme) {
                ForEach(GarminGlucoseColorScheme.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text(LocalizedString("Display", comment: "Garmin settings: display section"))
        }
    }
}
