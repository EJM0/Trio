import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date())
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        let entry = TrioWatchComplicationEntry(date: Date())
        completion(entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let entry = TrioWatchComplicationEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Views

//// Displayed View Wrapper
struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        #if os(watchOS)
            case .accessoryCorner:
                TrioAccessoryCornerView(entry: entry)
        #endif
        default:
            Image("ComplicationIcon")
                .widgetAccentable()
                .widgetBackground(backgroundView: Color.clear)
        }
    }
}

#if os(watchOS)
    /// Corner Complication
    struct TrioAccessoryCornerView: View {
        var entry: TrioWatchComplicationProvider.Entry

        var body: some View {
            Text("")
                .widgetCurvesContent()
                .widgetLabel {
                    Text("Trio")
                }
                .widgetBackground(backgroundView: Color.clear)
        }
    }
#endif

/// Circular Complication
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationProvider.Entry

    var body: some View {
        Image("ComplicationIcon")
            .resizable()
            .widgetAccentable()
            .widgetBackground(backgroundView: Color.clear)
    }
}

// MARK: - Widget Configuration

@main struct TrioWatchComplications: WidgetBundle {
    var body: some Widget {
        TrioWatchComplication()
        #if os(watchOS)
            TrioMealBolusComplication()
            if #available(watchOS 26.0, *) {
                TrioMealBolusControl()
            }
        #endif
    }
}

struct TrioWatchComplication: Widget {
    let kind: String = "TrioWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trio")
        .description("Displays Trio app icon as complication")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
            return [.accessoryCorner, .accessoryCircular]
        #else
            return [.accessoryCircular]
        #endif
    }
}

#if os(watchOS)
    // MARK: - Meal & Bolus Complication

    /// Opens the watch app on the carbs entry of the "Meal & Bolus" flow.
    struct TrioMealBolusComplication: Widget {
        let kind: String = "TrioMealBolusComplication"

        /// Must match `WatchShortcut.mealBolusURL` in the watch app.
        static let url = URL(string: "trio-watch://meal-bolus")!

        var body: some WidgetConfiguration {
            StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { _ in
                TrioMealBolusComplicationView()
                    .widgetURL(Self.url)
            }
            .configurationDisplayName(String(localized: "Meal & Bolus", comment: "Watch App Treatment Option 'Meal & Bolus'"))
            .description("Opens Trio to log a meal and a bolus")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
        }
    }

    /// The "Meal & Bolus" control for Control Center, the Smart Stack and the Action button (watchOS 26).
    @available(watchOS 26.0, *)
    struct TrioMealBolusControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: "TrioMealBolusControl") {
                ControlWidgetButton(action: OpenMealBolusIntent()) {
                    Label {
                        Text("Meal & Bolus", comment: "Watch App Treatment Option 'Meal & Bolus'")
                    } icon: {
                        Image(systemName: "fork.knife")
                    }
                }
            }
            .displayName("Meal & Bolus")
            .description("Opens Trio to log a meal and a bolus")
        }
    }

    struct TrioMealBolusComplicationView: View {
        @Environment(\.widgetFamily) private var widgetFamily

        var body: some View {
            switch widgetFamily {
            case .accessoryCorner:
                Image(systemName: "fork.knife")
                    .font(.title3)
                    .widgetAccentable()
                    .widgetLabel {
                        Text("Meal & Bolus", comment: "Watch App Treatment Option 'Meal & Bolus'")
                    }
                    .widgetBackground(backgroundView: Color.clear)
            case .accessoryInline:
                Label {
                    Text("Meal & Bolus", comment: "Watch App Treatment Option 'Meal & Bolus'")
                } icon: {
                    Image(systemName: "fork.knife")
                }
                .widgetBackground(backgroundView: Color.clear)
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "syringe.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .widgetAccentable()
                }
                .widgetBackground(backgroundView: Color.clear)
            }
        }
    }
#endif

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}
