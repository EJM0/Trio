//
//  AuthenticatedSettingsWrapper.swift
//  Trio
//
//  Created by Generated on $(DATE).
//
import LoopKitUI
import SwiftUI
import Swinject

struct AuthenticatedSettingsWrapper: BaseView {
    let resolver: Resolver

    @StateObject private var state = Settings.StateModel()
    @State private var isAuthenticated = false
    @Environment(\.authenticate) private var authenticate

    var body: some View {
        Group {
            if shouldRequireAuthentication && !isAuthenticated {
                AuthenticationView(onAuthenticated: {
                    isAuthenticated = true
                })
            } else {
                Settings.RootView(resolver: resolver)
            }
        }
        .onAppear {
            state.resolver = resolver
            // If lock settings is disabled, allow immediate access
            if !state.settingsManager.settings.lockSettingsViewEnabled {
                isAuthenticated = true
            }
        }
        .onChange(of: state.settingsManager.settings.lockSettingsViewEnabled) { _, newValue in
            // If lock settings is disabled while viewing, allow immediate access
            if !newValue {
                isAuthenticated = true
            } else {
                // If lock settings is enabled, require authentication again
                isAuthenticated = false
            }
        }
    }

    private var shouldRequireAuthentication: Bool {
        state.settingsManager.settings.lockSettingsViewEnabled
    }
}

struct AuthenticationView: View {
    let onAuthenticated: () -> Void
    @Environment(\.authenticate) private var authenticate
    @State private var authenticationError: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Authentication Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Please authenticate to access settings")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let error = authenticationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Authenticate") {
                performAuthentication()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            // Automatically trigger authentication on appear
            performAuthentication()
        }
    }

    private func performAuthentication() {
        authenticate("Authenticate to access settings") { result in
            switch result {
            case .success:
                authenticationError = nil
                onAuthenticated()
            case let .failure(error):
                authenticationError = "Authentication failed: \(error.localizedDescription)"
            }
        }
    }
}
