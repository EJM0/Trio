import SwiftUI

/// "Snoozed until 14:30" line for the alarm lists. Glucose alarms carry their
/// own `snoozedUntil`, device alarms snooze per severity tier — neither was
/// visible anywhere outside the banner that set it, so a snooze taken from a
/// notification looked like nothing had happened.
struct AlarmSnoozeBadge: View {
    let until: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
            Text(String(
                format: String(localized: "Snoozed until %@"),
                until.formatted(date: .omitted, time: .shortened)
            ))
        }
        .font(.footnote)
        .foregroundStyle(.tint)
    }
}
