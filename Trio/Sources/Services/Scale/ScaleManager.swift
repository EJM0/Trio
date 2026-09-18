import Foundation
import Swinject

protocol ScaleManager {
    /// Whether the live-weight websocket is currently up.
    var isScaleConnected: Bool { get }

    func tare(ip: String?)
    func calibrate(weight: Decimal, ip: String?)
    func fetchWeight(completion: @escaping (Double) -> Void)
    func fetchBatteryLevel(completion: @escaping (Int?) -> Void)

    func connectToWebSocket(
        ip: String?, onMessage: @escaping (Double) -> Void, onConnectionChange: ((Bool) -> Void)?
    )
    func disconnectWebSocket()
}

final class BaseScaleManager: ScaleManager, Injectable {
    @Injected() var settingsManager: SettingsManager!
    private var webSocketTask: URLSessionWebSocketTask?

    // Reconnection state
    private(set) var isScaleConnected = false
    private var shouldReconnect = false
    private var currentOnConnectionChange: ((Bool) -> Void)?

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
        debug(.service, "fetchWeight called with IP: \(ip)")
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):8080/read") else {
            debug(.service, "IP is empty or invalid URL for weight")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            debug(
                .service,
                "Weight response received - error: \(error?.localizedDescription ?? "none"), data: \(data?.count ?? 0) bytes"
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
        debug(.service, "fetchBatteryLevel called with IP: \(ip)")
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):8080/battery") else {
            debug(.service, "IP is empty or invalid URL")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            debug(
                .service,
                "Battery response received - error: \(error?.localizedDescription ?? "none"), data: \(data?.count ?? 0) bytes"
            )
            guard let data = data, error == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // The firmware sends {"voltage":3.76,"percent":51}. Trio decoded "percentage",
            // which never matched, so it always fell through to deriving its own number --
            // the scale showed 51% while the phone showed something else entirely.
            //
            // Double, not Int: firmware reporting a fractional percent failed an Int decode
            // and then fell through every branch to nil, showing no battery at all.
            struct BatteryPercentageResponse: Decodable {
                let percent: Double

                enum CodingKeys: String, CodingKey {
                    case percent
                    case percentage
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    guard let value = try container.decodeIfPresent(Double.self, forKey: .percent)
                        ?? container.decodeIfPresent(Double.self, forKey: .percentage)
                    else {
                        throw DecodingError.keyNotFound(
                            CodingKeys.percent,
                            .init(codingPath: container.codingPath, debugDescription: "no percent field")
                        )
                    }
                    percent = value
                }
            }

            struct BatteryVoltageResponse: Decodable {
                let voltage: Double
            }

            // The scale's own number always wins, so Trio shows what the device shows.
            if let response = try? JSONDecoder().decode(BatteryPercentageResponse.self, from: data) {
                DispatchQueue.main.async {
                    completion(Int(response.percent.rounded()))
                }
            }
            // Voltage JSON format
            else if let response = try? JSONDecoder().decode(BatteryVoltageResponse.self, from: data) {
                DispatchQueue.main.async {
                    completion(Self.batteryPercent(forVoltage: response.voltage))
                }
            }
            // Plain text voltage format like "3.92V"
            else if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
                let voltage = Double(text.replacingOccurrences(of: "V", with: ""))
            {
                DispatchQueue.main.async {
                    completion(Self.batteryPercent(forVoltage: voltage))
                }
            } else {
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }.resume()
    }

    /// Mirrors the scale firmware's own `battPercent()` so the two readings agree.
    ///
    /// Only reached when the scale sends volts without a percent; its own number is preferred,
    /// and this exists so the fallback does not disagree with the device either.
    ///
    /// A straight line is not how a LiPo actually discharges -- it reads high through the middle
    /// and falls off a cliff near the end. That is worth fixing, but in the firmware, which owns
    /// the number shown on the scale's own display; Trio would then follow for free through
    /// `percent`. Diverging here would only recreate the mismatch this replaced.
    ///
    /// ponytail: keep in step with BAT_EMPTY/BAT_FULL in scale.ino.
    static func batteryPercent(forVoltage voltage: Double) -> Int {
        let empty = 3.30
        let full = 4.20
        let ratio = (voltage - empty) / (full - empty) * 100
        return Int(max(0, min(100, ratio.rounded())))
    }

    func connectToWebSocket(
        ip: String? = nil,
        onMessage: @escaping (Double) -> Void,
        onConnectionChange: ((Bool) -> Void)? = nil
    ) {
        let ipToUse = ip ?? settingsManager.settings.scaleIP
        debug(.service, "connectToWebSocket called with IP: \(ipToUse)")
        guard !ipToUse.isEmpty else {
            debug(.service, "IP is empty for WebSocket")
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
            debug(.service, "Invalid WebSocket URL")
            return
        }

        debug(.service, "Connecting to WebSocket at \(url.absoluteString)")

        // Store parameters for reconnection
        currentOnConnectionChange = onConnectionChange
        shouldReconnect = true

        // Establish connection
        connect(url: url, onMessage: onMessage)
    }

    private func connect(url: URL, onMessage: @escaping (Double) -> Void) {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()

        isScaleConnected = true
        DispatchQueue.main.async { [weak self] in
            self?.currentOnConnectionChange?(true)
        }
        receiveMessage(onMessage: onMessage)
    }

    private func receiveMessage(onMessage: @escaping (Double) -> Void) {
        let currentTask = webSocketTask
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            // Only the active task speaks for the connection: an old task's cancellation
            // arrives here too, and must not be reported as this connection dropping.
            //
            // Deliberately not also gated on `shouldReconnect`. It is cleared by
            // disconnectWebSocket(), which the consumer calls from its own disconnect handler --
            // so a genuine drop that landed here while it was false was swallowed, the consumer
            // never heard "disconnected", and its reconnect polling never started. An
            // intentional disconnect nils the task, which this check already covers.
            guard self.webSocketTask === currentTask else { return }

            switch result {
            case let .failure(error):
                debug(.service, "WebSocket error: \(error)")
                self.handleConnectionFailure()

            case let .success(message):
                // Connected successfully

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

    private func handleConnectionFailure() {
        // We no longer auto-reconnect at the socket layer.
        // Instead, we just notify the consumer (StateModel) that connection is lost.
        // The consumer is responsible for falling back to polling (battery check) and then reconnecting.
        debug(.service, "WebSocket disconnected or error. Notifying consumer.")

        isScaleConnected = false
        DispatchQueue.main.async { [weak self] in
            self?.currentOnConnectionChange?(false)
        }

        // Clean up connection
        webSocketTask = nil
    }

    func disconnectWebSocket() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isScaleConnected = false
        // Do not notify listener here - this is an intentional disconnect initiated by the consumer
    }
}
