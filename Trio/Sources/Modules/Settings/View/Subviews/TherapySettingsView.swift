//
//  TherapySettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import LoopKitUI
import SwiftUI
import Swinject

struct TherapySettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel
    @State private var isAuthenticated = false
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState
    @Environment(\.authenticate) private var authenticate

    var body: some View {
        Group {
            if shouldRequireAuthentication && !isAuthenticated {
                AuthenticationView(onAuthenticated: {
                    isAuthenticated = true
                })
            } else {
                therapySettingsContent
            }
        }
        .onAppear {
            // If lock settings is enabled, skip therapy auth
            if state.settingsManager.settings.lockSettingsViewEnabled {
                isAuthenticated = true
            }
        }
        .onChange(of: state.settingsManager.settings.lockSettingsViewEnabled) { _, newValue in
            // If lock settings is enabled, skip therapy auth
            if newValue {
                isAuthenticated = true
            } else {
                // If lock settings is disabled, require therapy auth again
                isAuthenticated = false
            }
        }
    }

    private var shouldRequireAuthentication: Bool {
        !state.settingsManager.settings.lockSettingsViewEnabled
    }

    private var therapySettingsContent: some View {
        Form {
            Section(
                header: Text("Basic Settings"),
                content: {
                    Text("Units and Limits").navigationLink(to: .unitsAndLimits, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Basic Insulin Rates & Targets"),
                content: {
                    Text("Glucose Targets").navigationLink(to: .targetsEditor, from: self)
                    Text("Basal Rates").navigationLink(to: .basalProfileEditor, from: self)
                    Text("Carb Ratios").navigationLink(to: .crEditor, from: self)
                    Text("Insulin Sensitivities").navigationLink(to: .isfEditor, from: self)
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Therapy Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }
}
