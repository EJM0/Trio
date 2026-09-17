import Foundation

// MARK: - OpenFoodFacts Credential & Session Store

actor OpenFoodFactsAuthStore {
    private let keychain = BaseKeychain()
    private let usernameKey = "openFoodFactsUsername"
    private let passwordKey = "openFoodFactsPassword"
    private let cookieNameKey = "openFoodFactsSessionCookieName"
    private let cookieValueKey = "openFoodFactsSessionCookieValue"
    private let cookieExpiryKey = "openFoodFactsSessionCookieExpiry"

    private(set) var credentialsIfAvailable: Credentials?
    private var sessionCookie: SessionCookie?

    init() {
        if let username = keychainValue(forKey: usernameKey),
           let password = keychainValue(forKey: passwordKey),
           !username.isEmpty,
           !password.isEmpty
        {
            credentialsIfAvailable = Credentials(username: username, password: password)
        }

        if let cookieName = keychainValue(forKey: cookieNameKey),
           let cookieValue = keychainValue(forKey: cookieValueKey)
        {
            let cookieExpiry = storedCookieExpiry()
            sessionCookie = SessionCookie(name: cookieName, value: cookieValue, expiresAt: cookieExpiry)
        }
    }

    var hasCredentials: Bool {
        credentialsIfAvailable != nil
    }

    func setCredentials(username: String, password: String) {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUsername.isEmpty || password.isEmpty {
            credentialsIfAvailable = nil
            removeKeychainCredentials()
            clearStoredSessionCookie()
            clearOpenFoodFactsCookiesFromStorage()
            return
        }

        if let existingCredentials = credentialsIfAvailable,
           existingCredentials.username != trimmedUsername || existingCredentials.password != password
        {
            clearStoredSessionCookie()
            clearOpenFoodFactsCookiesFromStorage()
        }

        let credentials = Credentials(username: trimmedUsername, password: password)
        credentialsIfAvailable = credentials
        storeCredentialsInKeychain(credentials)
    }

    func storeSessionCookie(_ cookie: HTTPCookie) {
        let storedCookie = SessionCookie(name: cookie.name, value: cookie.value, expiresAt: cookie.expiresDate)
        sessionCookie = storedCookie
        _ = keychain.setValue(storedCookie.name, forKey: cookieNameKey)
        _ = keychain.setValue(storedCookie.value, forKey: cookieValueKey)
        if let expiresAt = storedCookie.expiresAt {
            storeCookieExpiry(expiresAt)
        } else {
            _ = keychain.removeObject(forKey: cookieExpiryKey)
        }
    }

    func hasValidSessionCookie(referenceDate: Date = Date()) -> Bool {
        validSessionCookieHeader(referenceDate: referenceDate) != nil
    }

    func validSessionCookieHeader(referenceDate: Date = Date()) -> String? {
        guard let sessionCookie else {
            return nil
        }

        if let expiresAt = sessionCookie.expiresAt, expiresAt <= referenceDate {
            clearStoredSessionCookie()
            return nil
        }

        return "\(sessionCookie.name)=\(sessionCookie.value)"
    }

    private func keychainValue(forKey key: String) -> String? {
        keychain.getValue(String.self, forKey: key)
    }

    private func storeCredentialsInKeychain(_ credentials: Credentials) {
        _ = keychain.setValue(credentials.username, forKey: usernameKey)
        _ = keychain.setValue(credentials.password, forKey: passwordKey)
    }

    private func removeKeychainCredentials() {
        _ = keychain.removeObject(forKey: usernameKey)
        _ = keychain.removeObject(forKey: passwordKey)
    }

    private func clearStoredSessionCookie() {
        sessionCookie = nil
        _ = keychain.removeObject(forKey: cookieNameKey)
        _ = keychain.removeObject(forKey: cookieValueKey)
        _ = keychain.removeObject(forKey: cookieExpiryKey)
    }

    private func storeCookieExpiry(_ date: Date) {
        let timestamp = date.timeIntervalSince1970
        _ = keychain.setValue(String(timestamp), forKey: cookieExpiryKey)
    }

    private func storedCookieExpiry() -> Date? {
        guard let timestampString = keychainValue(forKey: cookieExpiryKey),
              let timestamp = TimeInterval(timestampString)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func clearOpenFoodFactsCookiesFromStorage() {
        guard let cookies = HTTPCookieStorage.shared.cookies else {
            return
        }

        for cookie in cookies where cookie.domain.localizedCaseInsensitiveContains("openfoodfacts.org") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}

extension OpenFoodFactsAuthStore {
    struct Credentials {
        let username: String
        let password: String
    }

    struct SessionCookie {
        let name: String
        let value: String
        let expiresAt: Date?
    }
}
