import Foundation

// MARK: - Connected Scale

/// Polling and live-weight streaming for an optional network kitchen scale.
///
/// Split out because it is a self-contained device concern: it owns the only `Timer` in the
/// state model and the websocket lifecycle that `deinit` tears down. `scaleCheckTimer` and
/// `isCheckingScaleConnection` are stored properties, so they stay in the class body and can
/// no longer be `private` -- they are not meant to be touched from anywhere else.
extension MealManager.StateModel {
    // MARK: - Scale

    func startScalePolling() {
        // Cancel any existing timer
        scaleCheckTimer?.invalidate()

        // Check immediately
        checkScaleConnectionOnce()

        // Then check every 1 second
        scaleCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            self?.checkScaleConnectionOnce()
        }
    }

    func stopScalePolling() {
        scaleCheckTimer?.invalidate()
        scaleCheckTimer = nil
    }

    private func checkScaleConnectionOnce() {
        // Skip if already connected or checking
        guard liveScaleWeight == nil, !isCheckingScaleConnection else { return }

        isCheckingScaleConnection = true
        provider.scaleManager.fetchBatteryLevel { [weak self] level in
            guard let self = self else { return }
            self.isCheckingScaleConnection = false
            self.scaleBatteryLevel = level
            if level != nil {
                // Scale detected! Stop polling and start WebSocket
                self.stopScalePolling()
                self.startScaleStream()
            }
        }
    }

    func checkScaleConnection() {
        debug(
            .service,
            "checkScaleConnection called, liveScaleWeight: \(liveScaleWeight?.description ?? "nil")"
        )
        // Only fetch if not already connected/streaming
        if liveScaleWeight == nil {
            provider.scaleManager.fetchBatteryLevel { [weak self] level in
                debug(.service, "Battery level response: \(level?.description ?? "nil")")
                self?.scaleBatteryLevel = level
                if level != nil {
                    debug(.service, "Starting scale stream...")
                    self?.startScaleStream()
                }
            }
        } else {
            // Just update battery
            provider.scaleManager.fetchBatteryLevel { [weak self] level in
                debug(.service, "Battery level update: \(level?.description ?? "nil")")
                self?.scaleBatteryLevel = level
            }
        }
    }

    func startScaleStream() {
        debug(.service, "connectToWebSocket called")
        provider.scaleManager.connectToWebSocket(
            ip: nil,
            onMessage: { [weak self] weight in
                debug(.service, "Received weight from WebSocket: \(weight)")
                self?.liveScaleWeight = weight
            },
            onConnectionChange: { [weak self] isConnected in
                guard let self = self else { return }
                debug(.service, "Connection changed: \(isConnected)")
                if isConnected {
                    // Set initial weight to 0.0 if nil so UI shows "Connected" state
                    // while waiting for first reading
                    if self.liveScaleWeight == nil {
                        self.liveScaleWeight = 0.0
                    }
                } else {
                    self.liveScaleWeight = nil
                    // Ensure clean state in manager
                    self.provider.scaleManager.disconnectWebSocket()
                    // If connection lost, go back to polling
                    debug(.service, "Lost connection to scale. Switching back to polling.")
                    self.startScalePolling()
                }
            }
        )
    }

    func stopScaleStream() {
        stopScalePolling()
        provider?.scaleManager.disconnectWebSocket()
        liveScaleWeight = nil
        scaleBatteryLevel = nil
    }

    func fetchScaleWeight(completion: @escaping (Double) -> Void) {
        provider.scaleManager.fetchWeight(completion: completion)
    }

    func tareScale() {
        provider.scaleManager.tare(ip: nil)
    }}
