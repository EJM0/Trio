import SwiftUI

extension BolusCalculatorConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Published var units: GlucoseUnits = .mgdL
        @Published var overrideFactor: Decimal = 0
        @Published var fattyMeals: Bool = false
        @Published var fattyMealFactor: Decimal = 0
        @Published var sweetMeals: Bool = false
        @Published var sweetMealFactor: Decimal = 0
        @Published var displayPresets: Bool = true
        @Published var confirmBolusWhenVeryLowGlucose: Bool = false
        @Published var mealManagerScannerEnabled: Bool = false
        @Published var mealManagerOnlyCarbs: Bool = false
        @Published var openFoodFactsUsername: String = ""
        @Published var openFoodFactsPassword: String = ""
        @Published var isOpenFoodFactsLoginSuccessful: Bool = false
        @Published var isOpenFoodFactsLoginInProgress: Bool = false
        @Published var openFoodFactsLoginError: String?
        @Published var scaleIP: String = ""
        @Published var calibrationWeight: Decimal = 100

        func tareScale() {
            provider.scaleManager.tare(ip: scaleIP)
        }

        func calibrateScale() {
            provider.scaleManager.calibrate(weight: calibrationWeight, ip: scaleIP)
        }

        func loginToOpenFoodFacts() {
            let trimmedUsername = openFoodFactsUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUsername.isEmpty, !openFoodFactsPassword.isEmpty else {
                isOpenFoodFactsLoginSuccessful = false
                openFoodFactsLoginError = String(localized: "Please enter username and password.")
                return
            }

            isOpenFoodFactsLoginInProgress = true
            openFoodFactsLoginError = nil

            Task { @MainActor in
                await provider.openFoodFacts.setCredentials(username: trimmedUsername, password: openFoodFactsPassword)

                do {
                    let loginSuccessful = try await provider.openFoodFacts.login()
                    isOpenFoodFactsLoginSuccessful = loginSuccessful
                    if !loginSuccessful {
                        openFoodFactsLoginError = String(localized: "Login failed. Check username/password.")
                    }
                } catch {
                    isOpenFoodFactsLoginSuccessful = false
                    openFoodFactsLoginError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }

                isOpenFoodFactsLoginInProgress = false
            }
        }

        func disconnectAndRemoveOpenFoodFacts() {
            openFoodFactsUsername = ""
            openFoodFactsPassword = ""
            settingsManager.settings.openFoodFactsUsername = ""
            settingsManager.settings.openFoodFactsPassword = ""
            isOpenFoodFactsLoginSuccessful = false
            isOpenFoodFactsLoginInProgress = false
            openFoodFactsLoginError = nil

            Task { @MainActor in
                await provider.openFoodFacts.setCredentials(username: "", password: "")
            }
        }

        override func subscribe() {
            units = settingsManager.settings.units

            subscribeSetting(\.overrideFactor, on: $overrideFactor) { overrideFactor = $0 }
            subscribeSetting(\.fattyMeals, on: $fattyMeals) { fattyMeals = $0 }
            subscribeSetting(\.displayPresets, on: $displayPresets) { displayPresets = $0 }
            subscribeSetting(\.fattyMealFactor, on: $fattyMealFactor) { fattyMealFactor = $0 }
            subscribeSetting(\.sweetMeals, on: $sweetMeals) { sweetMeals = $0 }
            subscribeSetting(\.sweetMealFactor, on: $sweetMealFactor) { sweetMealFactor = $0 }
            subscribeSetting(\.confirmBolus, on: $confirmBolusWhenVeryLowGlucose) {
                confirmBolusWhenVeryLowGlucose = $0
            }
            subscribeSetting(\.mealManagerScannerEnabled, on: $mealManagerScannerEnabled) {
                mealManagerScannerEnabled = $0
            }
            subscribeSetting(\.mealManagerOnlyCarbs, on: $mealManagerOnlyCarbs) {
                mealManagerOnlyCarbs = $0
            }
            subscribeSetting(\.openFoodFactsUsername, on: $openFoodFactsUsername) {
                openFoodFactsUsername = $0
            }
            subscribeSetting(\.openFoodFactsPassword, on: $openFoodFactsPassword) {
                openFoodFactsPassword = $0
            }
            subscribeSetting(\.scaleIP, on: $scaleIP) { scaleIP = $0 }

            Task { @MainActor in
                await self.provider.openFoodFacts.setCredentials(
                    username: self.openFoodFactsUsername,
                    password: self.openFoodFactsPassword
                )
                self.isOpenFoodFactsLoginSuccessful = await self.provider.openFoodFacts.hasValidSessionCookie()
            }
        }
    }
}

extension BolusCalculatorConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
