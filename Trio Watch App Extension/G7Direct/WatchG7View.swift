import SwiftUI

/// The watch's own G7 reading: the switch, the latest reading and one status
/// line. Details, the log and the reset sit behind a button.
struct WatchG7View: View {
    @State private var showDetails = false

    private var reader: WatchG7Reader { WatchG7Reader.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { reader.isEnabled },
                    set: { reader.setEnabled($0) }
                )) {
                    Text("Watch sensor", comment: "Toggle: the watch reads the G7 itself")
                        .font(.footnote)
                }

                if reader.isEnabled, reader.isStandingAside {
                    // the old value would only count up; untethered mode's readings are on the first pages
                    Text(
                        "Untethered mode is reading the sensor. Its values are on the first pages.",
                        comment: "Watch sensor page while untethered mode holds the sensor"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button {
                        showDetails = true
                    } label: {
                        Text("Log", comment: "Button: open the watch sensor details and log")
                            .font(.footnote)
                    }
                } else if reader.isEnabled {
                    latestReading

                    Text(reader.statusText)
                        .font(.caption2)
                        .foregroundStyle(reader.isConnected || reader.freshReading != nil ? Color.secondary : Color.loopYellow)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Button {
                        showDetails = true
                    } label: {
                        Text("Log", comment: "Button: open the watch sensor details and log")
                            .font(.footnote)
                    }
                } else {
                    Text("Reads your G7 when the iPhone is away. No dosing.", comment: "One-line explanation under the watch sensor toggle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
        .sheet(isPresented: $showDetails) {
            WatchG7DetailsView()
        }
        .onAppear {
            reader.noteWake()
        }
    }

    private var latestReading: some View {
        VStack(spacing: 0) {
            if let latest = reader.latest {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(reader.format(Double(latest.glucose)))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(reader.arrow(for: latest.trendName))
                        .font(.title3)
                }
                Text(latest.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Everything for testing: what the watch knows, the log, and the reset.
struct WatchG7DetailsView: View {
    @State private var showResetConfirmation = false

    private var reader: WatchG7Reader { WatchG7Reader.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // to Messages or Mail, for whoever helps with testing
                ShareLink(
                    item: shareText,
                    subject: Text("Trio watch sensor log"),
                    preview: SharePreview("Trio watch sensor log")
                ) {
                    Label {
                        Text("Share log", comment: "Button: share the watch sensor log")
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.footnote)
                }

                VStack(alignment: .leading, spacing: 2) {
                    row(String(localized: "Sensor", comment: "Watch sensor details label"), reader.sensorName ?? "–")
                    row(String(localized: "Code", comment: "Watch sensor details label: pairing code received"), reader.pairingCode == nil ? "–" : "✓")
                    row(String(localized: "Paired", comment: "Watch sensor details label: the watch has its own key"), reader.hasWatchKey ? "✓" : "–")
                    row(String(localized: "Connected", comment: "Watch sensor details label"), reader.isConnected ? "✓" : "–")
                    let coverage = reader.recentCoverage
                    row(
                        String(localized: "Last 2 h", comment: "Watch sensor details label: readings received in the last two hours"),
                        "\(coverage.count)/\(coverage.expected) · max gap \(coverage.longestGapMinutes) min"
                    )
                    row(String(localized: "Units", comment: "Watch sensor details label"), reader.units)
                    row(
                        String(localized: "iPhone", comment: "Watch sensor details label: age of the last update from the phone"),
                        reader.lastPhoneContact.map { minutesAgo($0) } ?? "–"
                    )
                    row(
                        String(localized: "iPhone BG", comment: "Watch sensor details label: age of the phone's newest glucose"),
                        reader.phoneGlucoseDate.map { minutesAgo($0) } ?? "–"
                    )
                    if let problem = reader.sensorProblem {
                        row(String(localized: "State", comment: "Watch sensor details label: sensor state without a reading"), problem)
                    }
                }
                .font(.caption2)

                if !reader.logLines.isEmpty {
                    Divider()
                    ForEach(Array(reader.logLines.suffix(60).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Pair watch again", comment: "Button: forget the watch's own pairing with the sensor")
                        .font(.footnote)
                }
                .disabled(!reader.hasWatchKey)
            }
            .padding(.horizontal, 4)
        }
        .confirmationDialog(
            Text("Pair the watch with the sensor again?", comment: "Confirmation title for resetting the watch's sensor pairing"),
            isPresented: $showResetConfirmation
        ) {
            Button(role: .destructive) {
                reader.resetWatchPairing()
            } label: {
                Text("Pair again", comment: "Confirm resetting the watch's sensor pairing")
            }
        }
    }

    /// The details above the log, then the whole log (up to 200 lines), oldest first.
    private var shareText: String {
        let coverage = reader.recentCoverage
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        let header = [
            "Trio watch sensor log, \(Date().formatted(date: .abbreviated, time: .shortened))",
            "Trio \(version)",
            "Sensor: \(reader.sensorName ?? "–")",
            "Paired: \(reader.hasWatchKey ? "yes" : "no") · connected: \(reader.isConnected ? "yes" : "no")",
            "Last 2 h: \(coverage.count)/\(coverage.expected) readings, longest gap \(coverage.longestGapMinutes) min",
            "Units: \(reader.units)"
        ]
        return (header + [""] + reader.logLines).joined(separator: "\n")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
    }

    private func minutesAgo(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        return String(localized: "\(minutes) min ago", comment: "Watch sensor details: minutes since the last iPhone update")
    }
}
