import Foundation

// MARK: - OpenFoodFacts API Client

extension BarcodeScanner {
    /// Client for fetching product data from OpenFoodFacts API
    struct OpenFoodFactsClient {
        private static let authStore = OpenFoodFactsAuthStore()

        func setCredentials(username: String, password: String) async {
            await Self.authStore.setCredentials(username: username, password: password)
        }

        func hasValidSessionCookie() async -> Bool {
            await Self.authStore.hasValidSessionCookie()
        }

        @discardableResult func login() async throws -> Bool {
            guard let credentials = await Self.authStore.credentialsIfAvailable else {
                return false
            }

            // Requests new session cookie from OpenFoodFacts and stores it in the auth store for future requests
            let loginURL = URL(string: "https://world.openfoodfacts.org/cgi/session.pl")!
            var request = URLRequest(url: loginURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request
                .httpBody =
                "user_id=\(credentials.username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? credentials.username)&password=\(credentials.password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? credentials.password)"
                    .data(using: .utf8)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode
            else {
                return false
            }

            let responseHeaders = Dictionary(uniqueKeysWithValues: httpResponse.allHeaderFields.map {
                (String(describing: $0.key), String(describing: $0.value))
            })

            let cookies = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: loginURL)
            if let sessionCookie = cookies.first(where: { $0.name.localizedCaseInsensitiveContains("session") })
                ?? cookies.first
            {
                HTTPCookieStorage.shared.setCookie(sessionCookie)
                await Self.authStore.storeSessionCookie(sessionCookie)
                return true
            }

            if let storedCookie = HTTPCookieStorage.shared.cookies?.first(where: {
                $0.domain.contains("openfoodfacts.org") && $0.name.localizedCaseInsensitiveContains("session")
            }) {
                await Self.authStore.storeSessionCookie(storedCookie)
                return true
            }

            return false
        }

        /// Fetches a product from Open Food Facts using its barcode.
        ///
        /// - Parameter barcode: The barcode identifier of the product to retrieve.
        /// - Returns: A `FoodItem` mapped from the Open Food Facts product response.
        /// - Throws: `OpenFoodFactsError.productNotFound` if no product matches the barcode,
        ///   or `OpenFoodFactsError.invalidResponse` when the response is invalid.
        func fetchProduct(barcode: String) async throws -> FoodItem {
            guard
                let url =
                URL(
                    string:
                    "https://world.openfoodfacts.org/api/v2/product/\(barcode).json&fields=code,product_name,image_url,image_front_small_url,nutriments,serving_quantity_unit,serving_quantity,product_quantity,product_quantity_unit"
                )
            else {
                throw OpenFoodFactsError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // if creds are not set method returns unchanged request input
            request = try await applySessionCookie(to: request)

            let (data, response) = try await performRequestWithReauthentication(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenFoodFactsError.invalidResponse
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            // Try to decode the response even for 404s, as the API returns useful JSON
            let apiResponse = try decoder.decode(APIResponse.self, from: data)

            // Check if product was found based on status field in JSON
            guard apiResponse.status == 1, let productData = apiResponse.product else {
                throw OpenFoodFactsError.productNotFound
            }

            // For other HTTP errors (5xx, etc.), throw invalidResponse
            guard 200 ..< 500 ~= httpResponse.statusCode else {
                throw OpenFoodFactsError.invalidResponse
            }

            return makeFoodItem(from: productData, barcodeOverride: apiResponse.code)
        }

        /// Search products by name/text query
        /// - Parameters:
        ///   - query: The search term to look for
        ///   - page: Page number for pagination (1-indexed)
        ///   - pageSize: Number of results per page
        /// - Returns: Array of matching FoodItems
        func searchProducts(query: String, page: Int = 1, pageSize: Int = 24) async throws -> [FoodItem]
        {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }

            guard var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")
            else {
                throw OpenFoodFactsError.invalidResponse
            }

            components.queryItems = [
                URLQueryItem(name: "search_terms", value: query),
                URLQueryItem(name: "search_simple", value: "1"),
                URLQueryItem(name: "action", value: "process"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize))
            ]

            guard let url = components.url else {
                throw OpenFoodFactsError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Trio-iOS/1.0", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData // No cache
            request = try await applySessionCookie(to: request)

            let (data, response) = try await performRequestWithReauthentication(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenFoodFactsError.invalidResponse
            }

            if httpResponse.statusCode == 503 {
                throw OpenFoodFactsError.searchRateLimited
            }

            guard 200 ..< 300 ~= httpResponse.statusCode else {
                throw OpenFoodFactsError.invalidResponse
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            let searchResponse = try decoder.decode(SearchAPIResponse.self, from: data)

            return searchResponse.products.map { productData in
                makeFoodItem(from: productData)
            }
        }

        /// Uploads changed nutriments for an existing product to OpenFoodFacts.
        /// Only changed fields are sent to avoid overwriting existing unrelated values.
        func uploadNutritionCorrection(
            for item: FoodItem,
            comparedTo originalNutriments: FoodItem.Nutriments
        ) async throws -> Bool {
            guard let barcode = item.barcode?.trimmingCharacters(in: .whitespacesAndNewlines), !barcode.isEmpty else {
                return false
            }

            let changedParams = changedNutrimentParameters(
                current: item.nutriments,
                original: originalNutriments
            )
            guard !changedParams.isEmpty else {
                return false
            }

            guard let writeURL = URL(string: "https://world.openfoodfacts.org/cgi/product_jqm2.pl") else {
                throw OpenFoodFactsError.invalidResponse
            }

            var params: [String: String] = [
                "code": barcode,
                "nutrition_data": "on",
                "nutrition_data_per": item.nutriments.basis == .per100ml ? "100ml" : "100g"
            ]

            if let credentials = await Self.authStore.credentialsIfAvailable {
                params["user_id"] = credentials.username
                params["password"] = credentials.password
            }

            changedParams.forEach { key, value in
                params[key] = value
            }

            var request = URLRequest(url: writeURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request = try await applySessionCookie(to: request)
            request.httpBody = Self.makeFormURLEncodedBody(params)

            let (data, response) = try await performRequestWithReauthentication(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode
            else {
                throw OpenFoodFactsError.invalidResponse
            }

            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            if let status = jsonObject["status"] as? Int {
                return status == 1
            }

            if let result = jsonObject["result"] as? [String: Any],
               let status = result["status"] as? Int
            {
                return status == 1
            }

            return false
        }

        private func applySessionCookie(to request: URLRequest) async throws -> URLRequest {
            var authorizedRequest = request

            if let cookieHeader = await Self.authStore.validSessionCookieHeader() {
                authorizedRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                return authorizedRequest
            }

            if await Self.authStore.hasCredentials {
                _ = try await login()
                if let cookieHeader = await Self.authStore.validSessionCookieHeader() {
                    authorizedRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }
            }

            return authorizedRequest
        }

        private func performRequestWithReauthentication(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let firstAttempt = try await URLSession.shared.data(for: request)

            guard let firstResponse = firstAttempt.1 as? HTTPURLResponse else {
                throw OpenFoodFactsError.invalidResponse
            }

            let shouldReauthenticate = firstResponse.statusCode == 401
                || firstResponse.statusCode == 403
                || firstResponse.statusCode == 503

            guard shouldReauthenticate else {
                return firstAttempt
            }

            guard await Self.authStore.hasCredentials else {
                return firstAttempt
            }

            let loginSucceeded = try await login()
            guard loginSucceeded else {
                return firstAttempt
            }

            let retryRequest = try await applySessionCookie(to: request)
            return try await URLSession.shared.data(for: retryRequest)
        }

        private func makeFoodItem(from productData: ProductData, barcodeOverride: String? = nil) -> FoodItem {
            let imageSource = productData.imageURL.map(FoodItem.ImageSource.url) ?? .none

            return FoodItem(
                barcode: barcodeOverride ?? productData.code,
                name: productData.productName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? String(localized: "Unknown product"),
                brand: productData.primaryBrand,
                quantity: productData.quantity,
                servingSize: productData.servingSize,
                ingredients: productData.ingredientsText,
                imageSource: imageSource,
                defaultPortionIsMl: productData.defaultPortionIsMl,
                servingQuantity: productData.servingQuantity,
                servingQuantityUnit: productData.servingQuantityUnit,
                nutriments: .init(
                    basis: productData.nutriments?.basis ?? .per100g,
                    energyKcalPer100g: productData.nutriments?.energyKcal100g,
                    carbohydratesPer100g: productData.nutriments?.carbohydrates100g,
                    sugarsPer100g: productData.nutriments?.sugars100g,
                    fatPer100g: productData.nutriments?.fat100g,
                    proteinPer100g: productData.nutriments?.proteins100g,
                    fiberPer100g: productData.nutriments?.fiber100g
                )
            )
        }

        private func changedNutrimentParameters(
            current: FoodItem.Nutriments,
            original: FoodItem.Nutriments,
            epsilon: Double = 0.0001
        ) -> [String: String] {
            var params: [String: String] = [:]

            func putIfChanged(_ currentValue: Double?, _ originalValue: Double?, fieldName: String) {
                let lhs = currentValue ?? 0
                let rhs = originalValue ?? 0
                guard abs(lhs - rhs) > epsilon else {
                    return
                }

                params["nutriment_\(fieldName)"] = String(lhs)
                params["nutriment_\(fieldName)_unit"] = "g"
            }

            putIfChanged(current.carbohydratesPer100g, original.carbohydratesPer100g, fieldName: "carbohydrates")
            putIfChanged(current.fatPer100g, original.fatPer100g, fieldName: "fat")
            putIfChanged(current.proteinPer100g, original.proteinPer100g, fieldName: "proteins")

            return params
        }

        private static func makeFormURLEncodedBody(_ params: [String: String]) -> Data? {
            let body = params
                .map { key, value in
                    "\(urlEncode(key))=\(urlEncode(value))"
                }
                .joined(separator: "&")

            return body.data(using: .utf8)
        }

        private static func urlEncode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        }
    }
}

// MARK: - Errors

extension BarcodeScanner {
    enum OpenFoodFactsError: LocalizedError {
        case invalidResponse
        case productNotFound
        case searchRateLimited

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                String(localized: "Unable to reach OpenFoodFacts. Please try again.")
            case .productNotFound:
                String(
                    localized:
                    "We couldn’t find this barcode in OpenFoodFacts. Maybe add the product to OpenFoodFacts via the App."
                )
            case .searchRateLimited:
                String(
                    localized:
                    "Try logging in with your OpenFoodFacts account to reduce rate limits."
                )
            }
        }
    }
}

// MARK: - Private API Response Types

private extension BarcodeScanner.OpenFoodFactsClient {
    struct APIResponse: Decodable {
        let status: Int
        let statusVerbose: String
        let code: String
        let product: ProductData?
    }

    /// Response structure for search API endpoint
    struct SearchAPIResponse: Decodable {
        let count: Int
        let page: Int
        let pageSize: Int
        let products: [ProductData]
    }

    struct ProductData: Decodable {
        let code: String?
        let productName: String?
        let brands: String?
        let quantity: String?
        let productQuantityUnit: String?
        let servingSize: String?
        let servingQuantity: Double?
        let servingQuantityUnit: String?
        let productQuantity: Double?
        let ingredientsText: String?
        let imageUrl: String?
        let imageFrontUrl: String?
        let imageFrontThumbUrl: String?
        let nutriments: NutrimentsData?

        private enum CodingKeys: String, CodingKey {
            case code
            case productName
            case brands
            case quantity
            case productQuantityUnit
            case servingSize
            case servingQuantity
            case productQuantity
            case servingQuantityUnit
            case ingredientsText
            case imageUrl
            case imageFrontUrl
            case imageFrontThumbUrl
            case nutriments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decodeIfPresent(String.self, forKey: .code)
            productName = try container.decodeIfPresent(String.self, forKey: .productName)
            brands = try container.decodeIfPresent(String.self, forKey: .brands)
            quantity = try container.decodeIfPresent(String.self, forKey: .quantity)
            productQuantityUnit = try container.decodeIfPresent(String.self, forKey: .productQuantityUnit)
            servingSize = try container.decodeIfPresent(String.self, forKey: .servingSize)
            servingQuantityUnit = try container.decodeIfPresent(String.self, forKey: .servingQuantityUnit)
            ingredientsText = try container.decodeIfPresent(String.self, forKey: .ingredientsText)
            imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
            imageFrontUrl = try container.decodeIfPresent(String.self, forKey: .imageFrontUrl)
            imageFrontThumbUrl = try container.decodeIfPresent(String.self, forKey: .imageFrontThumbUrl)
            nutriments = try container.decodeIfPresent(NutrimentsData.self, forKey: .nutriments)

            servingQuantity = try container.decodeFlexibleDoubleIfPresent(forKey: .servingQuantity)
            productQuantity = try container.decodeFlexibleDoubleIfPresent(forKey: .productQuantity)
        }

        var primaryBrand: String? {
            brands?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first
        }

        var defaultPortionIsMl: Bool {
            let servingUnit = servingQuantityUnit?.lowercased() ?? productQuantityUnit?.lowercased()
            if let unit = servingUnit {
                return unit.contains("ml") || unit.contains("l") || unit.contains("fl oz")
            }
            return nutriments?.basis == .per100ml
        }

        var imageURL: URL? {
            [imageFrontUrl, imageFrontThumbUrl, imageUrl]
                .compactMap { $0 }
                .compactMap { URL(string: $0) }
                .first
        }
    }

    struct NutrimentsData: Decodable {
        let basis: BarcodeScanner.FoodItem.Nutriments.Basis
        let energyKcal100g: Double?
        let carbohydrates100g: Double?
        let sugars100g: Double?
        let fat100g: Double?
        let proteins100g: Double?
        let fiber100g: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode([String: NumericValue].self)

            func value(_ key: String, fallbacks: [String] = []) -> Double? {
                if let v = raw[key]?.doubleValue {
                    return v
                }
                for fb in fallbacks {
                    if let v = raw[fb]?.doubleValue {
                        return v
                    }
                }
                return nil
            }

            energyKcal100g = value(
                "energy-kcal_100g",
                fallbacks: ["energy-kcal_100ml", "energy-kcal_serving"]
            )
            carbohydrates100g = value(
                "carbohydrates_100g",
                fallbacks: ["carbohydrates_100ml", "carbohydrates_serving"]
            )
            sugars100g = value(
                "sugars_100g",
                fallbacks: ["sugars_100ml", "sugars_serving"]
            )
            fat100g = value(
                "fat_100g",
                fallbacks: ["fat_100ml", "fat_serving"]
            )
            proteins100g = value(
                "proteins_100g",
                fallbacks: ["proteins_100ml", "proteins_serving"]
            )
            fiber100g = value(
                "fiber_100g",
                fallbacks: ["fiber_100ml", "fiber_serving"]
            )

            // Decide if data is per 100g or per 100ml based on available keys
            let hasPer100g = raw.keys.contains { $0.hasSuffix("_100g") }
            let hasPer100ml = raw.keys.contains { $0.hasSuffix("_100ml") }

            if hasPer100ml, !hasPer100g {
                basis = .per100ml
            } else {
                basis = .per100g
            }
        }

        /// Helper type that can decode either a number or a string and expose it as Double
        private struct NumericValue: Decodable {
            let doubleValue: Double?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()

                if let d = try? container.decode(Double.self) {
                    doubleValue = d
                    return
                }

                if let s = try? container.decode(String.self) {
                    doubleValue = Double(s.replacingOccurrences(of: ",", with: "."))
                    return
                }

                doubleValue = nil
            }
        }
    }
}

// MARK: - Decoding Helpers

private extension KeyedDecodingContainer {
    /// Versucht, einen Wert erst als Double und dann als String (mit Komma-Konvertierung) zu decodieren.
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let doubleValue = try? decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

private actor OpenFoodFactsAuthStore {
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

private extension OpenFoodFactsAuthStore {
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
