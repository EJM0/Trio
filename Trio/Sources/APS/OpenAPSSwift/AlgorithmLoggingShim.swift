import Foundation

// MARK: - Package-only logging shim

//
// This file exists solely for the `Trio` SPM target declared in
// `AlgorithmPackage/Package.swift`, which compiles the oref algorithm (plus its
// models) as a standalone macOS-capable module so `swift test` can run the
// algorithm suite without building the iOS app or booting a simulator.
// The watch app compiles it too and routes the output to its own logger.
//

#if TRIO_ALGORITHM_PACKAGE || os(watchOS)

    /// Stands in for the app's `Logger` so `Logger.Category` resolves in the package.
    enum Logger {
        /// Mirrors `Logger.Category` in the app target.
        enum Category: String {
            case loop
            case algorithm
            case pump
            case cgm
            case bolus
            case treatments
            case nightscout
            case tidepool
            case remote
            case healthKit
            case alerts
            case watch
            case liveActivity
            case storage
            case settings
            case telemetry
            case ui
            case lifecycle
        }
    }

    enum AlgorithmLogLevel {
        case debug
        case info
        case warning
        case error
        case fault
    }

    /// Set by a test or the watch app to receive algorithm log output; defaults to discarding it.
    nonisolated(unsafe) var algorithmLogSink: ((AlgorithmLogLevel, Logger.Category, String, Swift.Error?) -> Void)?

    func debug(
        _ category: Logger.Category,
        _ message: @autoclosure () -> String,
        printToConsole _: Bool = true,
        file _: String = #file,
        function _: String = #function,
        line _: UInt = #line
    ) {
        algorithmLogSink?(.debug, category, message(), nil)
    }

    func info(
        _ category: Logger.Category,
        _ message: String,
        file _: String = #file,
        function _: String = #function,
        line _: UInt = #line
    ) {
        algorithmLogSink?(.info, category, message, nil)
    }

    func warning(
        _ category: Logger.Category,
        _ message: String,
        description: String? = nil,
        error maybeError: Swift.Error? = nil,
        file _: String = #file,
        function _: String = #function,
        line _: UInt = #line
    ) {
        algorithmLogSink?(.warning, category, composed(message, description), maybeError)
    }

    func error(
        _ category: Logger.Category,
        _ message: String,
        description: String? = nil,
        error maybeError: Swift.Error? = nil,
        file _: String = #file,
        function _: String = #function,
        line _: UInt = #line
    ) {
        algorithmLogSink?(.error, category, composed(message, description), maybeError)
    }

    func fault(
        _ category: Logger.Category,
        _ message: String,
        description: String? = nil,
        error maybeError: Swift.Error? = nil,
        file _: String = #file,
        function _: String = #function,
        line _: UInt = #line
    ) {
        algorithmLogSink?(.fault, category, composed(message, description), maybeError)
    }

    private func composed(_ message: String, _ description: String?) -> String {
        [message, description].compactMap { $0 }.joined(separator: ": ")
    }

#endif
