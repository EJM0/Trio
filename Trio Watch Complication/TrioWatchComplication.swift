import AppIntents
import Charts
import SwiftUI
import WidgetKit

// MARK: - Glucose from the watch app

/// Written by the watch app (ComplicationStore.swift); keep the two in step.
struct TrioComplicationData: Codable, Equatable {
    struct Point: Codable, Equatable {
        let date: Date
        /// In the display units.
        let value: Double
        /// "#RRGGBB" by Trio's glucose color scheme.
        var color: String?
    }

    var points: [Point]
    var isMmol: Bool
    var low: Double
    var high: Double
    var trend: String?
    var delta: String?
    var lastLoop: Date?
    var iob: String?
    var cob: String?
    var watchLoops: Bool

    static func load() -> TrioComplicationData? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              let data = UserDefaults(suiteName: group)?.data(forKey: "complication.glucose")
        else { return nil }
        return try? JSONDecoder().decode(TrioComplicationData.self, from: data)
    }
}

/// A reading older than this shows as stale: dashes, in grey.
private let staleAfter: TimeInterval = 15 * 60

/// Trio's own palette (the watch app's asset colors; the extension has none of its own).
private extension Color {
    static let trioLoopGreen = Color(red: 0.435, green: 0.812, blue: 0.592)
    static let trioLoopYellow = Color(red: 1.0, green: 0.757, blue: 0.271)
    static let trioLoopRed = Color(red: 0.922, green: 0.341, blue: 0.341)
    static let trioInsulin = Color(red: 0.118, green: 0.588, blue: 0.988)
    static let trioCarbs = Color.orange
    static let trioBubble = Color(red: 0.029, green: 0.083, blue: 0.155)
}

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    var data: TrioComplicationData?

    var latest: TrioComplicationData.Point? { data?.points.last }

    var isStale: Bool {
        guard let latest else { return true }
        return date.timeIntervalSince(latest.date) > staleAfter
    }

    /// Whole minutes since the reading, as the watch app counts them.
    var readingAge: Int? { latest.map { max(0, Int(date.timeIntervalSince($0.date) / 60)) } }

    /// The ring as on the watch's main screen: green up to 5 minutes since the loop, yellow to 10, red after.
    var loopColor: Color {
        guard let lastLoop = data?.lastLoop else { return .gray }
        let minutes = date.timeIntervalSince(lastLoop) / 60
        return minutes <= 5 ? .trioLoopGreen : minutes <= 10 ? .trioLoopYellow : .trioLoopRed
    }

    var glucoseText: String {
        guard let data, let latest, !isStale else { return "--" }
        return latest.value.formatted(.number.precision(.fractionLength(data.isMmol ? 1 : 0)))
    }

    var arrow: String {
        guard !isStale else { return "" }
        switch data?.trend {
        case "DoubleUp": return "⇈"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown": return "↓"
        case "DoubleDown": return "⇊"
        default: return ""
        }
    }

    var ageText: String { readingAge.map { "\($0)m" } ?? "" }

    /// The color the watch app stored for the reading (Trio's static or dynamic scheme), else by range.
    func color(_ point: TrioComplicationData.Point) -> Color {
        guard let data else { return .primary }
        if let hex = point.color, let stored = Color(hex: hex) { return stored }
        if point.value < data.low { return .trioLoopRed }
        if point.value > data.high { return .trioLoopYellow }
        return .trioLoopGreen
    }

    var glucoseColor: Color {
        guard let latest, !isStale else { return .gray }
        return color(latest)
    }
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date(), data: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        let data = TrioComplicationData.load() ?? (context.isPreview ? .preview : nil)
        completion(TrioWatchComplicationEntry(date: Date(), data: data))
    }

    /// The watch app reloads with every newer reading. Until then the reading's age counts up minute by minute, and
    /// the ring turns and the reading goes stale from entries, without a reload (as LoopKit/Loop#2562 does).
    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let now = Date()
        let data = TrioComplicationData.load()
        var dates = (0 ... 30).map { now.addingTimeInterval(Double($0) * 60) }
        if let lastLoop = data?.lastLoop {
            dates += [lastLoop.addingTimeInterval(5 * 60 + 1), lastLoop.addingTimeInterval(10 * 60 + 1)]
        }
        if let latest = data?.points.last?.date { dates.append(latest.addingTimeInterval(staleAfter + 1)) }
        let entries = Set(dates.filter { $0 >= now }).sorted().map { TrioWatchComplicationEntry(date: $0, data: data) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

extension TrioComplicationData {
    static var preview: TrioComplicationData {
        let now = Date()
        let values: [Double] = [142, 138, 131, 127, 122, 118, 116, 113, 112, 110, 108, 107]
        return TrioComplicationData(
            points: values.enumerated().map { index, value in
                Point(date: now.addingTimeInterval(Double(index - values.count + 1) * 5 * 60), value: value, color: nil)
            },
            isMmol: false,
            low: 70,
            high: 180,
            trend: "FortyFiveDown",
            delta: "-1",
            lastLoop: now.addingTimeInterval(-60),
            iob: "1.20",
            cob: "10",
            watchLoops: false
        )
    }
}

// MARK: - Views

struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily

    var entry: TrioWatchComplicationEntry

    var body: some View {
        if entry.data == nil {
            TrioIconView()
        } else {
            switch widgetFamily {
            case .accessoryRectangular:
                TrioAccessoryRectangularView(entry: entry)
            case .accessoryCircular:
                TrioAccessoryCircularView(entry: entry)
            case .accessoryInline:
                TrioAccessoryInlineView(entry: entry)
            #if os(watchOS)
                case .accessoryCorner:
                    TrioAccessoryCornerView(entry: entry)
            #endif
            default:
                TrioIconView()
            }
        }
    }
}

/// Until the watch app has written a reading.
struct TrioIconView: View {
    var body: some View {
        Image("ComplicationIcon")
            .resizable()
            .widgetAccentable()
            .widgetBackground(backgroundView: Color.clear)
    }
}

/// Trio's glucose bubble: the reading inside the loop ring, the ring's color telling the loop's age.
struct TrioGlucoseBubble: View {
    var entry: TrioWatchComplicationEntry
    var ringWidth: CGFloat = 3
    var valueSize: CGFloat = 17
    /// The time of the reading beneath the value.
    var showsTime = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            if renderingMode == .fullColor {
                Circle().fill(Color.trioBubble)
            } else {
                AccessoryWidgetBackground()
            }
            Circle()
                .inset(by: ringWidth / 2)
                .stroke(entry.loopColor, lineWidth: ringWidth)
                .shadow(color: entry.loopColor.opacity(0.6), radius: 2)
                .widgetAccentable()
            VStack(spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(entry.glucoseText)
                        .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(entry.glucoseColor)
                    Text(entry.arrow)
                        .font(.system(size: valueSize * 0.6, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                if showsTime, let latest = entry.latest {
                    Text(latest.date, style: .time)
                        .font(.system(size: valueSize * 0.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .padding(ringWidth + 2)
        }
    }
}

/// Circular: the bubble, as on the watch's main screen.
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        TrioGlucoseBubble(entry: entry, showsTime: true)
            .widgetBackground(backgroundView: Color.clear)
    }
}

#if os(watchOS)
    /// Corner: the reading with its arrow; the curved label has the change and the reading's age.
    struct TrioAccessoryCornerView: View {
        var entry: TrioWatchComplicationEntry

        var body: some View {
            Text(entry.glucoseText + entry.arrow)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(entry.glucoseColor)
                .widgetCurvesContent()
                .widgetLabel {
                    Text(entry.isStale ? "" : [entry.data?.delta, entry.ageText].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(entry.loopColor)
                }
                .widgetBackground(backgroundView: Color.clear)
        }
    }
#endif

/// Inline: one line, the reading first.
struct TrioAccessoryInlineView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        let parts: [String?] = [
            entry.glucoseText + entry.arrow,
            entry.isStale ? nil : entry.data?.delta,
            entry.isStale ? nil : entry.ageText,
            entry.data?.iob.map { "\($0)U" }
        ]
        Text(parts.compactMap { $0 }.joined(separator: " · "))
            .widgetBackground(backgroundView: Color.clear)
    }
}

/// Rectangular: the bubble beside the last 3 hours over the target range, with insulin and carbs on board in
/// Trio's colors above the graph.
struct TrioAccessoryRectangularView: View {
    var entry: TrioWatchComplicationEntry
    /// Full color only on faces set to a multicolor option; the others tint the complication in one color.
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var isFullColor: Bool { renderingMode == .fullColor }
    private let span: TimeInterval = 3 * 60 * 60

    var body: some View {
        if let data = entry.data {
            HStack(spacing: 6) {
                TrioGlucoseBubble(entry: entry, ringWidth: 2.5, valueSize: 16)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    header(data)
                    graph(data)
                }
            }
            .widgetBackground(backgroundView: Color.clear)
        }
    }

    private func header(_ data: TrioComplicationData) -> some View {
        HStack(spacing: 6) {
            Text(entry.isStale ? "--" : data.delta ?? "")
                .foregroundStyle(.secondary)
            if let iob = data.iob {
                Text("\(iob)U").foregroundStyle(isFullColor ? Color.trioInsulin : .primary)
            }
            if let cob = data.cob {
                Text("\(cob)g").foregroundStyle(isFullColor ? Color.trioCarbs : .primary)
            }
            Spacer(minLength: 0)
            if data.watchLoops {
                Image(systemName: "applewatch").foregroundStyle(entry.loopColor)
            }
            if let latest = entry.latest {
                Text(latest.date, style: .time).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func graph(_ data: TrioComplicationData) -> some View {
        let start = entry.date.addingTimeInterval(-span)
        let points = data.points.filter { $0.date >= start }
        let values = points.map(\.value) + [data.low, data.high]
        let padding = data.isMmol ? 0.5 : 10
        let yMin = (values.min() ?? data.low) - padding
        let yMax = (values.max() ?? data.high) + padding

        return Chart {
            RectangleMark(
                xStart: .value("Start", start),
                xEnd: .value("End", entry.date),
                yStart: .value("Low", data.low),
                yEnd: .value("High", data.high)
            )
            .foregroundStyle(isFullColor ? Color.trioLoopGreen.opacity(0.2) : Color.primary.opacity(0.15))
            ForEach(points, id: \.date) { point in
                PointMark(x: .value("Time", point.date), y: .value("Glucose", point.value))
                    .symbolSize(point.date == points.last?.date ? 24 : 9)
                    .foregroundStyle(entry.isStale ? Color.secondary : entry.color(point))
                    // in one tint, readings out of range stand out by brightness
                    .opacity(isFullColor || point.value < data.low || point.value > data.high ? 1 : 0.55)
            }
        }
        .chartXScale(domain: start ... entry.date)
        .chartYScale(domain: yMin ... yMax)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .widgetAccentable(!isFullColor)
    }
}

// MARK: - Insulin and carbs on board

/// What the on-board complications show: IOB, COB or both.
enum OnBoardContent {
    case iob, cob, both
}

extension TrioWatchComplicationEntry {
    /// IOB and COB come with the loop: dashes once it is as old as a stale reading.
    var isOnBoardStale: Bool {
        guard let lastLoop = data?.lastLoop else { return true }
        return date.timeIntervalSince(lastLoop) > staleAfter
    }

    var iobText: String {
        guard !isOnBoardStale, let iob = data?.iob, let value = Double(iob) else { return "--" }
        return value.formatted(.number.precision(.fractionLength(abs(value) < 10 ? 1 : 0)))
    }

    var cobText: String {
        guard !isOnBoardStale, let cob = data?.cob, let value = Double(cob) else { return "--" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

/// IOB in Trio's insulin blue, COB in carbs orange; one tint on faces that don't show full color.
struct TrioOnBoardView: View {
    var entry: TrioWatchComplicationEntry
    var content: OnBoardContent
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var isFullColor: Bool { renderingMode == .fullColor }
    private var iobColor: Color { isFullColor ? .trioInsulin : .primary }
    private var cobColor: Color { isFullColor ? .trioCarbs : .primary }

    var body: some View {
        Group {
            switch widgetFamily {
            case .accessoryInline:
                inline
            #if os(watchOS)
                case .accessoryCorner:
                    corner
            #endif
            default:
                circular
            }
        }
        .widgetBackground(backgroundView: Color.clear)
    }

    private var inline: some View {
        switch content {
        case .iob: return Text("IOB \(entry.iobText) U")
        case .cob: return Text("COB \(entry.cobText) g")
        case .both: return Text("\(entry.iobText) U · \(entry.cobText) g")
        }
    }

    #if os(watchOS)
        private var corner: some View {
            let (value, label, color): (String, String, Color) = {
                switch content {
                case .iob: return ("\(entry.iobText)U", "IOB", iobColor)
                case .cob: return ("\(entry.cobText)g", "COB", cobColor)
                case .both: return ("\(entry.iobText)U", "\(entry.cobText) g COB", iobColor)
                }
            }()
            return Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .widgetCurvesContent()
                .widgetLabel {
                    Text(label).foregroundStyle(content == .both ? cobColor : .secondary)
                }
        }
    #endif

    private var circular: some View {
        ZStack {
            if isFullColor {
                Circle().fill(Color.trioBubble)
            } else {
                AccessoryWidgetBackground()
            }
            switch content {
            case .iob:
                single(icon: "syringe.fill", value: entry.iobText, unit: "U", color: iobColor)
            case .cob:
                single(icon: "fork.knife", value: entry.cobText, unit: "g", color: cobColor)
            case .both:
                VStack(spacing: 0) {
                    Text("\(entry.iobText)U").foregroundStyle(iobColor)
                    Rectangle().fill(.secondary).frame(width: 22, height: 1).padding(.vertical, 1)
                    Text("\(entry.cobText)g").foregroundStyle(cobColor)
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(4)
            }
        }
        .widgetAccentable()
    }

    private func single(icon: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(4)
    }
}

/// One configuration for the three: WidgetKit builds each widget with `init()`, so each is its own type.
private func onBoardConfiguration(
    kind: String,
    content: OnBoardContent,
    name: String,
    summary: String
) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
        TrioOnBoardView(entry: entry, content: content)
    }
    .configurationDisplayName(name)
    .description(summary)
    .supportedFamilies(onBoardFamilies)
}

private var onBoardFamilies: [WidgetFamily] {
    #if os(watchOS)
        return [.accessoryCircular, .accessoryCorner, .accessoryInline]
    #else
        return [.accessoryCircular, .accessoryInline]
    #endif
}

struct TrioIOBComplication: Widget {
    var body: some WidgetConfiguration {
        onBoardConfiguration(
            kind: "TrioIOBComplication",
            content: .iob,
            name: String(localized: "Insulin on Board"),
            summary: String(localized: "Trio's insulin on board")
        )
    }
}

struct TrioCOBComplication: Widget {
    var body: some WidgetConfiguration {
        onBoardConfiguration(
            kind: "TrioCOBComplication",
            content: .cob,
            name: String(localized: "Carbs on Board"),
            summary: String(localized: "Trio's carbs on board")
        )
    }
}

struct TrioOnBoardComplication: Widget {
    var body: some WidgetConfiguration {
        onBoardConfiguration(
            kind: "TrioOnBoardComplication",
            content: .both,
            name: String(localized: "Insulin & Carbs"),
            summary: String(localized: "Trio's insulin and carbs on board")
        )
    }
}

// MARK: - Widget Configuration

@main struct TrioWatchComplications: WidgetBundle {
    var body: some Widget {
        TrioWatchComplication()
        TrioIOBComplication()
        TrioCOBComplication()
        TrioOnBoardComplication()
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
        .description("Glucose in Trio's loop ring, with the last 3 hours in the wide slot")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
            return [.accessoryCorner, .accessoryCircular, .accessoryInline, .accessoryRectangular]
        #else
            return [.accessoryCircular]
        #endif
    }
}

extension Color {
    /// "#RRGGBB"
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let rgb = UInt64(digits, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
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
    @available(watchOS 26.0, *) struct TrioMealBolusControl: ControlWidget {
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
