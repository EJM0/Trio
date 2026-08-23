import CoreData
import SwiftDate
import SwiftUI
import UIKit

struct LoopView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Config {
        static let lag: TimeInterval = 30
        /// Floor for how long the spin stays up, so a sub-second loop still reads as work.
        static let minimumSpinDuration: TimeInterval = 2
    }

    let closedLoop: Bool
    let timerDate: Date
    let isLooping: Bool
    let lastLoopDate: Date
    let manualTempBasal: Bool

    let determination: [OrefDetermination]

    /// `isLooping`, but never shown for less than `Config.minimumSpinDuration`: a loop can
    /// finish in well under a second, and a pill that flickers on and off reads as a glitch
    /// rather than as work. A loop that runs longer than that ends the spin when it ends.
    @State private var showLooping: Bool = false
    @State private var spinStart: Date? = nil

    var body: some View {
        loopStatusContent
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .capsuleSpinner(isActive: showLooping, color: color)
            .task(id: isLooping) {
                if isLooping {
                    spinStart = Date()
                    showLooping = true
                } else {
                    // nothing was spinning (first run, or a stop that already elapsed)
                    guard let spinStart else {
                        showLooping = false
                        return
                    }

                    let remaining = Config.minimumSpinDuration - Date().timeIntervalSince(spinStart)
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                        guard !Task.isCancelled else { return }
                    }

                    showLooping = false
                    self.spinStart = nil
                }
            }
    }

    private var loopStatusContent: some View {
        HStack(alignment: .center) {
            ZStack {
                Image(systemName: (!closedLoop || manualTempBasal) ? "circle.and.line.horizontal" : "circle")
                    .symbolEffect(.pulse, options: .repeating, isActive: showLooping && !reduceMotion)
            }
            if showLooping, reduceMotion {
                // neither the spinning border nor the pulse runs here, so say it in words
                Text("Looping", comment: "Loop status label while a loop cycle is running")
            } else if manualTempBasal {
                Text("Manual")
            } else if determination.first?
                .deliverAt !=
                nil
            {
                // previously the .timestamp property was used here because this only gets updated when the reportenacted function in the aps manager gets called
                Text(timeString)
            } else {
                Text("--")
            }
        }
        .font(.callout).fontWeight(.bold).fontDesign(.rounded)
        .foregroundColor(color)
    }

    private var timeString: String {
        let minutesAgo = TimeAgoFormatter.minutesAgoValue(from: lastLoopDate)
        if minutesAgo > 1440 {
            return "--"
        } else {
            return TimeAgoFormatter.minutesAgo(from: lastLoopDate)
        }
    }

    private var color: Color {
        guard determination.first?.timestamp != nil
        else {
            // previously the .timestamp property was used here because this only gets updated when the reportenacted function in the aps manager gets called
            return .secondary
        }
        guard manualTempBasal == false else {
            return .loopManualTemp
        }
        guard closedLoop == true else {
            return .secondary
        }

        let delta = timerDate.timeIntervalSince(lastLoopDate) - Config.lag

        if delta <= 5.minutes.timeInterval {
            guard determination.first?.timestamp != nil else {
                return .loopYellow
            }
            return .loopGreen
        } else if delta <= 10.minutes.timeInterval {
            return .loopYellow
        } else {
            return .loopRed
        }
    }
}

extension View {
    func animateForever(
        using animation: Animation = Animation.easeInOut(duration: 1),
        autoreverses: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        let repeated = animation.repeatForever(autoreverses: autoreverses)

        return onAppear {
            withAnimation(repeated) {
                action()
            }
        }
    }
}
