import Combine
import ConnectIQ
import G7SensorKit
import LoopKit
import SwiftUI

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var garmin: GarminManager!
        @Injected() private var fetchGlucoseManager: FetchGlucoseManager!

        @Published var units: GlucoseUnits = .mgdL
        @Published var devices: [IQDevice] = []
        @Published var confirmBolusFaster = false
        @Published var showForecastWatch = false
        @Published var showGlucoseBubbleWatch = true
        @Published var useCriticalAlertsWatch = false
        /// The CGM is a G7, whose "Read on Apple Watch" lets the watch read it.
        @Published var cgmIsG7 = false
        @Published var watchReadsSensor = false
        @Published var watchLoopEnabled = false
        @Published var watchLoopWithoutPhone = false
        @Published var watchLoopFallback = false

        /// Garmin watch settings containing all watch-related configuration
        @Published var garminSettings = GarminWatchSettings()

        private(set) var preferences = Preferences()

        override func subscribe() {
            preferences = provider.preferences
            units = settingsManager.settings.units

            // Subscribe to the entire garminSettings struct from TrioSettings
            subscribeSetting(\.garminSettings, on: $garminSettings) { garminSettings = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.showForecastWatch, on: $showForecastWatch) { showForecastWatch = $0 }
            subscribeSetting(\.showGlucoseBubbleWatch, on: $showGlucoseBubbleWatch) { showGlucoseBubbleWatch = $0 }
            subscribeSetting(\.useCriticalAlertsWatch, on: $useCriticalAlertsWatch) { useCriticalAlertsWatch = $0 }
            subscribeSetting(\.watchLoopEnabled, on: $watchLoopEnabled) { watchLoopEnabled = $0 }
            subscribeSetting(\.watchLoopWithoutPhone, on: $watchLoopWithoutPhone) { watchLoopWithoutPhone = $0 }
            subscribeSetting(\.watchLoopFallback, on: $watchLoopFallback) { watchLoopFallback = $0 }

            devices = garmin.devices
            refreshWatchSensor()
        }

        /// The G7 manager's own setting is the source; this only shows it.
        func refreshWatchSensor() {
            let cgm = fetchGlucoseManager.cgmManager
            cgmIsG7 = cgm is G7CGMManager
            watchReadsSensor = (cgm as? DeviceConfigurationSharing)?.isConfigurationSharingEnabled ?? false
        }

        /// Prompts the user to select Garmin devices and updates the device list
        func selectGarminDevices() {
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        /// Updates the Garmin manager with the current device list
        func deleteGarminDevice() {
            garmin.updateDeviceList(devices)
        }

        /// Handles watchface selection changes by automatically disabling data transmission
        /// to allow the user to switch watchfaces on their Garmin device without data conflicts
        func handleWatchfaceChange() {
            garminSettings.isWatchfaceDataEnabled = false
        }

        /// Resumes data transmission after user confirms they have switched watchface on their device
        func resumeDataTransmission() {
            garminSettings.isWatchfaceDataEnabled = true
        }
    }
}

extension WatchConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
