import AppIntents
import SwiftUI
import WidgetKit

enum ProviderPalette {
    static func accent(for name: String, dark: Bool) -> Color {
        let lower = name.lowercased()
        if lower.contains("claude") {
            return dark ? Color(red: 0.90, green: 0.55, blue: 0.42) : Color(red: 0.80, green: 0.42, blue: 0.29)
        }
        if lower.contains("grok") {
            return dark ? Color(red: 0.91, green: 0.91, blue: 0.92) : Color(red: 0.12, green: 0.12, blue: 0.12)
        }
        return .teal
    }

    static func ramp(_ fraction: Double, accent: Color) -> Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.6 { return .orange }
        return accent
    }

    static func short(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("claude") { return "Claude" }
        if lower.contains("grok") { return "Grok" }
        if lower.contains("opencode") { return "opencode" }
        return name
    }
}

/// A single rendering-mode-aware source of truth. Every widget view branches here and nowhere
/// else, so tinted/clear Home Screen (`.accented`) and Lock Screen/StandBy (`.vibrant`) stay
/// legible: color ramps flatten to `.primary`, and cards fall back to a solid fill + hairline
/// stroke instead of a material that would vanish under accenting.
struct WidgetStyle {
    let mode: WidgetRenderingMode
    let dark: Bool

    var isFullColor: Bool { mode == .fullColor }
    var drawSheen: Bool { mode == .fullColor }
    var cardFill: Double { mode == .accented ? 0.16 : 0.06 }
    var cardStroke: Double { mode == .accented ? 0.35 : 0.10 }

    func accent(_ name: String) -> Color {
        isFullColor ? ProviderPalette.accent(for: name, dark: dark) : .primary
    }

    func ramp(_ fraction: Double, accent: Color) -> Color {
        isFullColor ? ProviderPalette.ramp(fraction, accent: accent) : .primary
    }
}

struct UsageWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription("Select which providers to show.")

    @Parameter(title: "Show", default: .all)
    var providerFilter: ProviderFilter

    enum ProviderFilter: String, AppEnum {
        case all
        case claude
        case grok
        case opencode

        static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
        static let caseDisplayRepresentations: [ProviderFilter: DisplayRepresentation] = [
            .all: "All Providers",
            .claude: "Claude Code",
            .grok: "Grok",
            .opencode: "opencode",
        ]
    }
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetStore.previewEntry()
    }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageWidgetEntry {
        UsageWidgetStore.read() ?? UsageWidgetStore.previewEntry()
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        guard let stored = UsageWidgetStore.read() else {
            return Timeline(entries: [emptyEntry()], policy: .after(Date().addingTimeInterval(900)))
        }
        let entry = filtered(stored, for: configuration.providerFilter)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900)))
    }

    private func emptyEntry() -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), providers: [], isStale: false)
    }

    private func filtered(_ entry: UsageWidgetEntry, for filter: UsageWidgetIntent.ProviderFilter) -> UsageWidgetEntry {
        guard filter != .all else { return entry }
        var copy = entry
        copy.providers = entry.providers.filter { provider in
            switch filter {
            case .all: return true
            case .claude: return provider.providerName.lowercased().contains("claude")
            case .grok: return provider.providerName.lowercased().contains("grok")
            case .opencode: return provider.providerName.lowercased().contains("opencode")
            }
        }
        return copy
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: UsageWidgetStore.kind, intent: UsageWidgetIntent.self, provider: UsageTimelineProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { ContainerBackdrop(entry: entry) }
        }
        .configurationDisplayName("Usage")
        .description("Live agent spend and rate-limit quotas across your coding servers.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct UsageWidgetEntryView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(entry: entry)
        case .systemMedium: MediumUsageView(entry: entry)
        case .systemLarge: LargeUsageView(entry: entry)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        case .accessoryCircular: AccessoryCircularView(entry: entry)
        case .accessoryInline: AccessoryInlineView(entry: entry)
        default: SmallUsageView(entry: entry)
        }
    }
}

private struct RankedGauge: Identifiable {
    let id: String
    let providerName: String
    let subtitle: String
    let label: String
    let fraction: Double
    let percentText: String
    let caption: String
    let resetsAt: Date?
    let isLive: Bool
}

private func rank(_ provider: UsageWidgetEntry.ProviderSnapshot, _ gauge: UsageWidgetEntry.GaugeSnapshot) -> RankedGauge {
    RankedGauge(
        id: provider.providerName + ":" + gauge.label,
        providerName: provider.providerName,
        subtitle: provider.subtitle,
        label: gauge.label,
        fraction: gauge.fraction,
        percentText: gauge.percentText,
        caption: gauge.caption,
        resetsAt: gauge.resetsAt,
        isLive: provider.isLive)
}

private func peakFraction(_ provider: UsageWidgetEntry.ProviderSnapshot) -> Double {
    provider.gauges.map(\.fraction).max() ?? 0
}

/// Providers, hottest first, so a maxed-out quota always floats to the top of every family.
private func orderedProviders(_ entry: UsageWidgetEntry) -> [UsageWidgetEntry.ProviderSnapshot] {
    entry.providers.sorted { peakFraction($0) > peakFraction($1) }
}

private func peakGauge(_ provider: UsageWidgetEntry.ProviderSnapshot) -> RankedGauge? {
    guard let gauge = provider.gauges.max(by: { $0.fraction < $1.fraction }) else { return nil }
    return rank(provider, gauge)
}

/// A provider's gauges hottest-first, so truncating to N never drops the most urgent one.
private func gauges(of provider: UsageWidgetEntry.ProviderSnapshot) -> [RankedGauge] {
    provider.gauges.map { rank(provider, $0) }.sorted { $0.fraction > $1.fraction }
}

private func globalHottest(_ entry: UsageWidgetEntry) -> RankedGauge? {
    orderedProviders(entry).first.flatMap(peakGauge)
}

private func usageURL() -> URL { URL(string: "tailscode://usage")! }

private func shortGaugeLabel(_ label: String) -> String {
    let lower = label.lowercased()
    if lower.contains("cache") { return "Cache" }
    if lower.contains("input") { return "Input" }
    if lower.contains("output") { return "Output" }
    if lower.contains("reason") { return "Reason" }
    if lower.contains("chat") { return "Chat" }
    if lower.contains("build") { return "Build" }
    if lower.contains("credit") { return "Credits" }
    if lower.contains("5-hour") || lower.contains("5 hour") { return "5-hour" }
    if lower.contains("fable") { return "Fable" }
    if lower.contains("all models") { return "All models" }
    if lower.contains("month") { return "Monthly" }
    if lower.contains("week") { return "Weekly" }
    return label
}

private func compactRemaining(_ resetsAt: Date, from: Date) -> String {
    let seconds = max(0, resetsAt.timeIntervalSince(from))
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 {
        return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m"
    }
    let days = hours / 24
    return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
}

struct ContainerBackdrop: View {
    let entry: UsageWidgetEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let name = orderedProviders(entry).first?.providerName ?? "Claude Code"
        let accent = ProviderPalette.accent(for: name, dark: colorScheme == .dark)
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [accent.opacity(0.22), accent.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct SmallUsageView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    private var style: WidgetStyle { WidgetStyle(mode: renderingMode, dark: colorScheme == .dark) }

    var body: some View {
        let providers = orderedProviders(entry)
        Group {
            if providers.isEmpty {
                EmptyUsageView()
            } else {
                stacked(providers)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(usageURL())
    }

    /// One provider → its gauges; several → each provider's hottest gauge. Every row is a
    /// label+percent line over a full-width bar, so bars stay visible at small's width.
    private func stacked(_ providers: [UsageWidgetEntry.ProviderSnapshot]) -> some View {
        let single = providers.count == 1
        let rows = single
            ? Array(gauges(of: providers[0]).prefix(3))
            : Array(providers.prefix(3).compactMap(peakGauge))
        return VStack(spacing: 7) {
            HStack(spacing: 4) {
                Text(single ? ProviderPalette.short(providers[0].providerName) : "Usage")
                    .font(.caption.weight(.bold)).lineLimit(1)
                if single {
                    StatusDot(isLive: providers[0].isLive, isStale: entry.isStale)
                }
                Spacer(minLength: 2)
                if let hottest = rows.first {
                    ResetLabel(entryDate: entry.date, resetsAt: hottest.resetsAt, caption: "", font: .system(size: 9, design: .monospaced))
                }
            }
            ForEach(rows) { row in
                smallRow(row, label: single ? shortGaugeLabel(row.label) : ProviderPalette.short(row.providerName))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func smallRow(_ gauge: RankedGauge, label: String) -> some View {
        let color = style.ramp(gauge.fraction, accent: style.accent(gauge.providerName))
        return VStack(spacing: 2.5) {
            HStack(spacing: 4) {
                Circle().fill(style.accent(gauge.providerName)).frame(width: 5, height: 5)
                Text(label)
                    .font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                if gauge.fraction > 0.85 { SeverityGlyph(size: 8) }
                Text(gauge.percentText)
                    .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(color)
            }
            GaugeBar(fraction: gauge.fraction, color: color).frame(height: 5)
        }
    }
}

struct MediumUsageView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    private var style: WidgetStyle { WidgetStyle(mode: renderingMode, dark: colorScheme == .dark) }

    var body: some View {
        let providers = Array(orderedProviders(entry).prefix(3))
        if providers.isEmpty {
            EmptyUsageView().widgetURL(usageURL())
        } else {
            ViewThatFits(in: .vertical) {
                stack(providers, maxGauges: 3, captions: true)
                stack(providers, maxGauges: 3, captions: false)
                stack(providers, maxGauges: 2, captions: false)
                stack(providers, maxGauges: 1, captions: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .widgetURL(usageURL())
        }
    }

    private func stack(_ providers: [UsageWidgetEntry.ProviderSnapshot], maxGauges: Int, captions: Bool) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(providers.enumerated()), id: \.element.providerName) { index, provider in
                ProviderRow(
                    provider: provider, style: style, entryDate: entry.date, isStale: entry.isStale,
                    maxGauges: maxGauges, showCaptions: captions)
                if index < providers.count - 1 {
                    Divider()
                }
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: UsageWidgetEntry.ProviderSnapshot
    let style: WidgetStyle
    let entryDate: Date
    let isStale: Bool
    let maxGauges: Int
    let showCaptions: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle().fill(style.accent(provider.providerName)).frame(width: 6, height: 6)
                    Text(ProviderPalette.short(provider.providerName))
                        .font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                }
                StatusPill(isLive: provider.isLive, isStale: isStale, accent: style.accent(provider.providerName))
            }
            .frame(width: 88, alignment: .leading)
            GaugeTable(
                gauges: Array(gauges(of: provider).prefix(maxGauges)), style: style,
                entryDate: entryDate, abbreviate: true, showCaptions: showCaptions)
                .frame(maxWidth: .infinity)
        }
    }
}

struct LargeUsageView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    private var style: WidgetStyle { WidgetStyle(mode: renderingMode, dark: colorScheme == .dark) }

    var body: some View {
        let providers = Array(orderedProviders(entry).prefix(3))
        if providers.isEmpty {
            EmptyUsageView().widgetURL(usageURL())
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                ViewThatFits(in: .vertical) {
                    cards(providers, maxGauges: 3, captions: true)
                    cards(providers, maxGauges: 3, captions: false)
                    cards(providers, maxGauges: 2, captions: false)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .widgetURL(usageURL())
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Usage").font(.headline.weight(.bold))
            Spacer()
            if entry.isStale {
                Text("STALE")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            } else {
                HStack(spacing: 3) {
                    Text("Updated")
                    Text(entry.date, style: .relative)
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func cards(_ providers: [UsageWidgetEntry.ProviderSnapshot], maxGauges: Int, captions: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(providers, id: \.providerName) { provider in
                LargeProviderCard(
                    provider: provider, style: style, entryDate: entry.date, isStale: entry.isStale,
                    maxGauges: maxGauges, showCaptions: captions)
            }
        }
    }
}

private struct LargeProviderCard: View {
    let provider: UsageWidgetEntry.ProviderSnapshot
    let style: WidgetStyle
    let entryDate: Date
    let isStale: Bool
    let maxGauges: Int
    let showCaptions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(style.accent(provider.providerName)).frame(width: 7, height: 7)
                Text(provider.providerName).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !provider.subtitle.isEmpty {
                    Text(provider.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                if !showCaptions, let peak = peakGauge(provider) {
                    ResetLabel(entryDate: entryDate, resetsAt: peak.resetsAt, caption: "", font: .caption2)
                }
                StatusPill(isLive: provider.isLive, isStale: isStale, accent: style.accent(provider.providerName))
            }
            GaugeTable(
                gauges: Array(gauges(of: provider).prefix(maxGauges)), style: style,
                entryDate: entryDate, abbreviate: false, showCaptions: showCaptions)
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(style.cardFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(style.cardStroke), lineWidth: 0.5))
        }
    }
}

struct AccessoryRectangularView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        if entry.providers.isEmpty {
            Text("No usage data").font(.caption2).foregroundStyle(.secondary)
        } else {
            let rows = accessoryRows(entry)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        Text(row.label)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if row.fraction > 0.85 {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                        }
                        Text(row.percentText)
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                        Spacer(minLength: 2)
                        GaugeBar(fraction: row.fraction, color: .primary)
                            .frame(width: 42, height: 4)
                    }
                }
            }
        }
    }
}

struct AccessoryCircularView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        if let hero = globalHottest(entry) {
            Gauge(value: min(1, max(0, hero.fraction))) {
                Text(ProviderPalette.short(hero.providerName).prefix(1))
            } currentValueLabel: {
                if hero.fraction > 0.85 {
                    Image(systemName: "exclamationmark.triangle.fill")
                } else {
                    Text("\(Int((hero.fraction * 100).rounded()))")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .minimumScaleFactor(0.5)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

struct AccessoryInlineView: View {
    let entry: UsageWidgetEntry

    var body: some View {
        if let hero = globalHottest(entry) {
            Label(inlineText(hero), systemImage: hero.fraction > 0.85 ? "exclamationmark.triangle.fill" : "gauge.with.needle")
        } else {
            Label("No usage data", systemImage: "gauge.with.dots.needle")
        }
    }

    private func inlineText(_ hero: RankedGauge) -> String {
        var text = "\(ProviderPalette.short(hero.providerName)) \(hero.percentText)"
        if let resetsAt = hero.resetsAt, resetsAt > entry.date {
            text += " · \(compactRemaining(resetsAt, from: entry.date))"
        }
        return text
    }
}

private func accessoryRows(_ entry: UsageWidgetEntry) -> [(label: String, fraction: Double, percentText: String)] {
    let providers = orderedProviders(entry)
    if providers.count == 1, let provider = providers.first {
        return provider.gauges.prefix(3).map { (shortGaugeLabel($0.label), $0.fraction, $0.percentText) }
    }
    return providers.prefix(3).compactMap { provider in
        guard let top = provider.gauges.max(by: { $0.fraction < $1.fraction }) else { return nil }
        return (ProviderPalette.short(provider.providerName), top.fraction, top.percentText)
    }
}

struct HeroRing: View {
    fileprivate let gauge: RankedGauge
    let style: WidgetStyle
    let size: CGFloat
    let lineWidth: CGFloat

    private var fill: Color { style.ramp(gauge.fraction, accent: style.accent(gauge.providerName)) }
    private var trimmed: CGFloat { CGFloat(max(0.001, min(1, gauge.fraction))) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: trimmed)
                .stroke(strokeStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: style.drawSheen ? fill.opacity(0.30) : .clear, radius: 3)
            Text(gauge.percentText)
                .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
    }

    private var strokeStyle: AnyShapeStyle {
        if style.drawSheen {
            return AnyShapeStyle(AngularGradient(
                gradient: Gradient(colors: [fill.opacity(0.75), fill]),
                center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
        }
        return AnyShapeStyle(fill)
    }
}

struct GaugeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(max(0.03, min(1, fraction))))
            }
        }
    }
}

private struct GaugeTable: View {
    let gauges: [RankedGauge]
    let style: WidgetStyle
    let entryDate: Date
    var abbreviate: Bool
    var showCaptions = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 5) {
            ForEach(gauges) { gauge in
                let color = style.ramp(gauge.fraction, accent: style.accent(gauge.providerName))
                GridRow {
                    Text(abbreviate ? shortGaugeLabel(gauge.label) : gauge.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .gridColumnAlignment(.leading)
                    GaugeBar(fraction: gauge.fraction, color: color)
                        .frame(height: 6)
                    HStack(spacing: 2) {
                        if gauge.fraction > 0.85 { SeverityGlyph(size: 8) }
                        Text(gauge.percentText)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(color)
                    }
                    .gridColumnAlignment(.trailing)
                }
                if showCaptions, let caption = captionText(gauge) {
                    GridRow {
                        Text(caption)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .gridCellColumns(3)
                    }
                }
            }
        }
    }

    private func captionText(_ gauge: RankedGauge) -> String? {
        if let resetsAt = gauge.resetsAt, resetsAt > entryDate {
            return "resets \(compactRemaining(resetsAt, from: entryDate))"
        }
        return gauge.caption.isEmpty ? nil : gauge.caption
    }
}

private struct ResetLabel: View {
    let entryDate: Date
    let resetsAt: Date?
    let caption: String
    var font: Font = .caption2

    var body: some View {
        if let resetsAt, resetsAt > entryDate {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                if resetsAt.timeIntervalSince(entryDate) < 3600 {
                    Text(timerInterval: entryDate...resetsAt, pauseTime: nil, countsDown: true, showsHours: false)
                        .monospacedDigit()
                } else {
                    Text(compactRemaining(resetsAt, from: entryDate)).monospacedDigit()
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if !caption.isEmpty {
            Text(caption)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct StatusDot: View {
    let isLive: Bool
    let isStale: Bool

    var body: some View {
        if isLive {
            Circle()
                .fill(isStale ? Color.secondary : Color.green)
                .frame(width: 6, height: 6)
        }
    }
}

private struct StatusPill: View {
    let isLive: Bool
    let isStale: Bool
    let accent: Color

    private var tint: Color { isStale ? .secondary : accent }

    var body: some View {
        HStack(spacing: 3) {
            Text(isLive ? "LIVE" : "EST")
                .font(.system(size: 8.5, weight: .heavy))
            if isLive {
                Circle()
                    .fill(isStale ? Color.secondary : Color.green)
                    .frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(isLive ? 0.15 : 0.10)))
    }
}

private struct SeverityGlyph: View {
    var size: CGFloat = 9
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size))
            .foregroundStyle(.red)
    }
}

struct EmptyUsageView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No usage data")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Connect a server to see quotas")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
