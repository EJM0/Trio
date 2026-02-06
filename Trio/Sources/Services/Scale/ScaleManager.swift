import Foundation
import Swinject

protocol ScaleManager {
    func tare(ip: String?)
    func calibrate(weight: Decimal, ip: String?)
    func fetchWeight(completion: @escaping (Double) -> Void)
    func fetchBatteryLevel(completion: @escaping (Int?) -> Void)
    func connectToWebSocket(ip: String?, onMessage: @escaping (Double) -> Void)
    func disconnectWebSocket()
}

final class BaseScaleManager: ScaleManager, Injectable {
    @Injected() var settingsManager: SettingsManager!
    private var webSocketTask: URLSessionWebSocketTask?

    // Reconnection state
    private var isConnectedToWebSocket = false
    private var shouldReconnect = false
    private var currentConnectionIP: String?
    private var currentOnMessage: ((Double) -> Void)?
    private var reconnectWorkItem: DispatchWorkItem?

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func tare(ip: String? = nil) {
        let ipToUse = ip ?? settingsManager.settings.scaleIP
        guard !ipToUse.isEmpty, let url = URL(string: "http://\(ipToUse):8080/tare") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    func calibrate(weight: Decimal, ip: String? = nil) {
        let ipToUse = ip ?? settingsManager.settings.scaleIP
        guard !ipToUse.isEmpty else { return }

        let weightString = NSDecimalNumber(decimal: weight).description(
            withLocale: Locale(identifier: "en_US")
        )

        guard let url = URL(string: "http://\(ipToUse):8080/calibrate?weight=\(weightString)") else {
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    func fetchWeight(completion: @escaping (Double) -> Void) {
        let ip = settingsManager.settings.scaleIP
        print("DEBUG ScaleManager: fetchWeight called with IP: \(ip)")
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):8080/read") else {
            print("DEBUG ScaleManager: IP is empty or invalid URL for weight")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            print(
                "DEBUG ScaleManager: Weight response received - error: \(error?.localizedDescription ?? "none"), data: \(data?.count ?? 0) bytes"
            )

            guard let data = data, error == nil else { return }

            struct ScaleResponse: Decodable {
                let weight: Decimal
            }

            if let response = try? JSONDecoder().decode(ScaleResponse.self, from: data) {
                DispatchQueue.main.async {
                    completion(NSDecimalNumber(decimal: response.weight).doubleValue)
                }
            }
        }.resume()
    }

    func fetchBatteryLevel(completion: @escaping (Int?) -> Void) {
        let ip = settingsManager.settings.scaleIP
        print("DEBUG ScaleManager: fetchBatteryLevel called with IP: \(ip)")
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):8080/battery") else {
            print("DEBUG ScaleManager: IP is empty or invalid URL")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            print(
                "DEBUG ScaleManager: Battery response received - error: \(error?.localizedDescription ?? "none"), data: \(data?.count ?? 0) bytes"
            )
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            struct BatteryPercentageResponse: Decodable {
                let percentage: Int
            }

            struct BatteryVoltageResponse: Decodable {
                let voltage: Double
            }

            // Try percentage format first
            if let response = try? JSONDecoder().decode(BatteryPercentageResponse.self, from: data) {
                DispatchQueue.main.async {
                    completion(response.percentage)
                }
            }
            // Try voltage JSON format
            else if let response = try? JSONDecoder().decode(BatteryVoltageResponse.self, from: data) {
                // Map 3.0V (0%) to 4.2V (100%)
                let minV = 3.0
                let maxV = 4.2
                let pct = Int(max(0, min(100, (response.voltage - minV) / (maxV - minV) * 100)))

                DispatchQueue.main.async {
                    completion(pct)
                }
            }
            // Try plain text voltage format like "3.92V"
            else if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
                let voltage = Double(text.replacingOccurrences(of: "V", with: ""))
            {
                // Map 3.0V (0%) to 4.2V (100%)
                let minV = 3.0
                let maxV = 4.2
                let pct = Int(max(0, min(100, (voltage - minV) / (maxV - minV) * 100)))

                DispatchQueue.main.async {
                    completion(pct)
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }.resume()
    }

    func connectToWebSocket(ip: String? = nil, onMessage: @escaping (Double) -> Void) {
        let ipToUse = ip ?? settingsManager.settings.scaleIP
        print("DEBUG ScaleManager: connectToWebSocket called with IP: \(ipToUse)")
        guard !ipToUse.isEmpty else {
            print("DEBUG ScaleManager: IP is empty for WebSocket")
            return
        }

        var wsPort = 8081
        var host = ipToUse

        // Handle explicit port in IP string (e.g. for emulator 192.168.1.1:8080)
        let parts = ipToUse.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) {
            host = String(parts[0])
            wsPort = port
        }

        guard let url = URL(string: "ws://\(host):\(wsPort)") else {
            print("DEBUG ScaleManager: Invalid WebSocket URL")
            return
        }

        print("DEBUG ScaleManager: Connecting to WebSocket at \(url.absoluteString)")

        // Store parameters for reconnection
        currentConnectionIP = ip
        currentOnMessage = onMessage
        shouldReconnect = true
        reconnectWorkItem?.cancel()

        // Establish connection
        connect(url: url, onMessage: onMessage)
    }

    private func connect(url: URL, onMessage: @escaping (Double) -> Void) {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()

        isConnectedToWebSocket = true
        receiveMessage(onMessage: onMessage)
    }

    private func receiveMessage(onMessage: @escaping (Double) -> Void) {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.shouldReconnect else { return }

            switch result {
            case let .failure(error):
                print("WebSocket error: \(error)")
                self.scheduleReconnect()

            case let .success(message):
                self.reconnectWorkItem?.cancel() // Connected successfully

                switch message {
                case let .string(text):
                    if let weight = Double(text) {
                        // Clamp weight to valid range (0 or positive)
                        let validWeight = max(0, weight)
                        DispatchQueue.main.async {
                            onMessage(validWeight)
                        }
                    }
                case .data:
                    break
                @unknown default:
                    break
                }

                self.receiveMessage(onMessage: onMessage)
            }
        }
    }

    private func scheduleReconnect() {
        isConnectedToWebSocket = false
        reconnectWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.shouldReconnect else { return }

            // Reconstruct URL from stored IP
            let ipToUse = self.currentConnectionIP ?? self.settingsManager.settings.scaleIP
            guard !ipToUse.isEmpty else { return }

            var wsPort = 8081
            var host = ipToUse

            let parts = ipToUse.split(separator: ":")
            if parts.count == 2, let port = Int(parts[1]) {
                host = String(parts[0])
                wsPort = port
            }

            if let url = URL(string: "ws://\(host):\(wsPort)"), let onMessage = self.currentOnMessage {
                print("Reconnecting to WebSocket...")
                self.connect(url: url, onMessage: onMessage)
            }
        }

        reconnectWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: item)
    }

    func disconnectWebSocket() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnectedToWebSocket = false
    }
}
