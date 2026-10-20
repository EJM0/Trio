import Foundation
import WatchConnectivity

actor WatchLogger {
    static let shared = WatchLogger()

    private var logs: [String] = []
    private let maxEntries = 500
    private let flushInterval: TimeInterval = 3 * 60
    private let flushSizeThreshold = 100
    private var lastFlush = Date()

    private let session = WCSession.default
    private var timerTask: Task<Void, Never>?

    private init() {
        Task {
            await startFlushTimer()
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }

    private func startFlushTimer() async {
        timerTask = Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await flushIfNeeded(force: false)
            }
        }
    }

    func log(
        _ message: String,
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(shortFile):\(line)] \(function) → \(message)"

        logs.append(entry)
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }

        print(entry)
        await flushIfNeeded(force: force)
    }

    func flushIfNeeded(force: Bool = false) async {
        let now = Date()
        let shouldFlush = force || now.timeIntervalSince(lastFlush) >= flushInterval || logs.count >= flushSizeThreshold

        if shouldFlush {
            await flushToPhone()
        }
    }

    private func flushToPhone() async {
        guard !logs.isEmpty else {
            return
        }
        let entries = logs
        logs.removeAll()
        lastFlush = Date()

        // Pump ownership, dosing, and hand-back messages take priority over diagnostic logs.
        guard !UntetheredWatchManager.shared.isActive, !UntetheredWatchManager.shared.isBusy else {
            await persistLogsLocally(entries)
            return
        }
        await queueInBackground(entries)
    }

    private func queueInBackground(_ entries: [String]) async {
        guard !entries.isEmpty else { return }
        guard session.activationState == .activated else {
            session.activate()
            await persistLogsLocally(entries)
            return
        }
        let text = entries.joined(separator: "\n")
        for part in Self.parts(of: text) {
            _ = session.transferUserInfo(["watchLogs": part])
        }
    }

    func persistLogsLocally(_ entries: [String]? = nil) async {
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFile = logDir.appendingPathComponent("watch_log.txt")
        let previousLogFile = logDir.appendingPathComponent("watch_log_prev.txt")
        let startOfDay = Calendar.current.startOfDay(for: Date())

        if let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let creationDate = attributes[.creationDate] as? Date,
           creationDate < startOfDay
        {
            try? FileManager.default.removeItem(at: previousLogFile)
            try? FileManager.default.moveItem(at: logFile, to: previousLogFile)
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.creationDate: startOfDay])
        }

        let fullLog = (entries ?? logs).joined(separator: "\n") + "\n"
        if let data = fullLog.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                try? handle.seekToEnd()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// Diagnostic logs are always background traffic and stay on disk while the watch owns the pump.
    func flushPersistedLogs() async {
        guard !UntetheredWatchManager.shared.isActive, !UntetheredWatchManager.shared.isBusy else { return }
        await flushToPhone()
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)
        let logFile = logDir.appendingPathComponent("watch_log.txt")

        guard let data = try? Data(contentsOf: logFile),
              let logString = String(data: data, encoding: .utf8),
              !logString.isEmpty
        else { return }

        guard session.activationState == .activated else {
            session.activate()
            return
        }

        // hours kept back while the phone was away are far over what one transfer takes ("payload too large"): in
        // parts, each of which the phone appends
        for part in Self.parts(of: logString) {
            let payload: [String: Any] = ["watchLogs": part]
            _ = session.transferUserInfo(payload)
        }
        try? FileManager.default.removeItem(at: logFile)
    }

    /// WatchConnectivity refuses a payload a little over 64 KB; whole lines, at most `maxBytes` each part.
    static func parts(of log: String, maxBytes: Int = 48000) -> [String] {
        var parts: [String] = []
        var current = ""
        var size = 0
        for line in log.split(separator: "\n") {
            let lineSize = line.utf8.count + 1
            if size > 0, size + lineSize > maxBytes {
                parts.append(current)
                current = ""
                size = 0
            }
            current += line + "\n"
            size += lineSize
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
