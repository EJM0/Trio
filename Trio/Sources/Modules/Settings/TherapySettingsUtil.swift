import Foundation

/// Utility class for handling common therapy settings authentication and saving patterns
class TherapySettingsUtil {
    /// Handles authentication for therapy settings and executes the provided save operation
    /// - Parameters:
    ///   - unlockManager: The unlock manager for authentication
    ///   - settingName: Name of the setting being saved (for logging)
    ///   - saveOperation: The save operation to execute after authentication
    /// - Returns: Boolean indicating if the save was successful
    @MainActor static func authenticateAndSave(
        using unlockManager: UnlockManager,
        settingName: String,
        saveOperation: @escaping () async throws -> Void
    ) async -> Bool {
        do {
            let authenticated = try await unlockManager.unlock()
            guard authenticated else {
                debug(.default, "\(settingName) save cancelled: Authentication failed")
                return false
            }

            try await saveOperation()
            debug(.default, "\(settingName) save completed successfully")
            return true
        } catch {
            debug(.default, "\(settingName) save failed: \(error)")
            return false
        }
    }

    /// Parse authentication error for user-friendly messages
    /// - Parameter error: The authentication error
    /// - Returns: User-friendly error message
    static func parseAuthenticationError(from _: Error) -> String {
        // This could be extracted from TreatmentsStateModel if needed
        "Authentication failed. Please try again."
    }
}
