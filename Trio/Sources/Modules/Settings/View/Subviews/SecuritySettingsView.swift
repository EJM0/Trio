//
//  SecuritySettingsView.swift
//  Trio
//
//  Created by Generated on $(DATE).
//
import Foundation
import SwiftUI
import Swinject

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
}

extension SecuritySettingsView {
    private var footerText: some View {
        Text(
            "When enabled, accessing the settings menu requires authentication, but therapy settings can be accessed directly without authentication."
        )
        .font(.footnote)
        .foregroundColor(.secondary)
    }
}
