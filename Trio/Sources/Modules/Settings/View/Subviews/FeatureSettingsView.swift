//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct FeatureSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Trio Features"),
                content: {
                    Text("Bolus Calculator").navigationLink(to: .bolusCalculatorConfig, from: self)
                    Text("Meal Settings").navigationLink(to: .mealSettings, from: self)
                    Text("Shortcuts").navigationLink(to: .shortcutsConfig, from: self)
                    Text("Remote Control").navigationLink(to: .remoteControlConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Trio Personalization"),
                content: {
                    Text("User Interface").navigationLink(to: .userInterfaceSettings, from: self)
                    Text("App Icons").navigationLink(to: .iconConfig, from: self)
                    NavigationLink(destination: SecuritySettingsView(resolver: resolver, state: state)) {
                        Text("Security")
                    }
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Anonymized Data Sharing"),
                content: {
                    Text("App Diagnostics").navigationLink(to: .appDiagnostics, from: self)
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Feature Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }
}

struct SecuritySettingsView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Authentication Settings"),
                footer: footerText,
                content: {
                    Toggle("Lock Settings View", isOn: $state.lockSettingsViewEnabled)
                        .onChange(of: state.lockSettingsViewEnabled) { _, newValue in
                            state.settingsManager.settings.lockSettingsViewEnabled = newValue
                        }
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Security Settings")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            state.lockSettingsViewEnabled = state.settingsManager.settings.lockSettingsViewEnabled
        }
    }

    private var footerText: some View {
        Text(
            "When enabled, accessing the settings menu requires authentication, but therapy settings can be accessed directly without authentication."
        )
        .font(.footnote)
        .foregroundColor(.secondary)
    }
}
