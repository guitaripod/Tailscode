import AppIntents
import SwiftUI
import TailscodeCore
import WidgetKit

/// What one render of the Usage widget draws: the reading, already made, and the choices the person
/// made in the widget's own editor. Nothing here asks a question — a widget is rendered at a moment
/// nobody chose, in a process with no connection, so every decision is taken before it arrives.
struct UsageEntry: TimelineEntry {
    let date: Date
    let glance: WidgetGlance
    let accent: WidgetAccentChoice
    let showsReset: Bool
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    /// Entries the widget can move through on its own — the countdown ticks and the reading ages
    /// without spending one of the day's few timeline reloads.
    private static let steps: [TimeInterval] = [0, 600, 1_200, 1_800]
    private static let refreshAfter: TimeInterval = 1_800

    func placeholder(in context: Context) -> UsageEntry {
        entry(from: UsageWidgetStore.previewEntry(), configuration: nil, at: Date())
    }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageEntry {
        let stored = UsageWidgetStore.read() ?? UsageWidgetStore.previewEntry()
        return entry(from: stored, configuration: configuration, at: Date())
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<
        UsageEntry
    > {
        if !context.isPreview { await Self.refreshLiveQuotas() }
        let now = Date()
        guard let stored = UsageWidgetStore.read() else {
            let empty = UsageWidgetEntry(date: now, providers: [], isStale: false)
            return Timeline(
                entries: [entry(from: empty, configuration: configuration, at: now)],
                policy: .after(now.addingTimeInterval(900)))
        }
        let entries = Self.steps.map { step in
            entry(from: stored, configuration: configuration, at: now.addingTimeInterval(step))
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refreshAfter)))
    }

    private func entry(
        from stored: UsageWidgetEntry, configuration: UsageWidgetIntent?, at moment: Date
    ) -> UsageEntry {
        UsageEntry(
            date: moment,
            glance: stored.glance(
                grouping: configuration?.grouping.grouping ?? .automatic,
                detail: configuration?.detail.detail ?? .automatic,
                providerFilter: configuration?.providerFilter,
                now: moment),
            accent: configuration?.accent ?? .theme,
            showsReset: configuration?.showsReset ?? true)
    }

    /// Widget-side self-refresh: pulls live quotas straight from the bridges inside the
    /// extension's own budget, so the widget keeps moving without the app foregrounding.
    /// The heavy opencode scan stays on the app/background-refresh side; its last stored
    /// gauges keep rendering. A fetch failure (tailnet down, phone offline) just serves
    /// the stored snapshot, which flips to CACHED on its own. The throttle collapses the
    /// burst of per-family timeline calls a single reload fans out into one fetch.
    private static func refreshLiveQuotas() async {
        if let stored = UsageWidgetStore.read(), Date().timeIntervalSince(stored.date) < 120 {
            return
        }
        let quotas = await LiveQuotaFetcher.fetch(deadline: 15)
        guard !quotas.isEmpty else {
            AppLogger.session.info("widget: live quota refresh got nothing; serving stored snapshot")
            return
        }
        UsageWidgetStore.writeLive(quotas, reload: false)
        AppLogger.session.info("widget: timeline reload refreshed \(quotas.count) live quota(s)")
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: UsageWidgetStore.kind, intent: UsageWidgetIntent.self,
            provider: UsageTimelineProvider()
        ) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { BackdropForEntry(entry: entry) }
        }
        .configurationDisplayName(String(localized: "Usage"))
        .description(
            String(localized: "Live agent spend and rate-limit quotas across your coding servers."))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

private struct BackdropForEntry: View {
    let entry: UsageEntry
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ContainerBackdrop(
            glance: entry.glance,
            palette: WidgetPalette.resolve(
                choice: entry.accent, dark: colorScheme == .dark, mode: renderingMode))
    }
}

func usageURL() -> URL { URL(string: "tailscode://usage")! }

struct UsageWidgetEntryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var palette: WidgetPalette {
        WidgetPalette.resolve(
            choice: entry.accent, dark: colorScheme == .dark, mode: renderingMode)
    }

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(entry: entry, palette: palette)
        case .systemMedium: MediumUsageView(entry: entry, palette: palette)
        case .systemLarge: LargeUsageView(entry: entry, palette: palette)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        case .accessoryCircular: AccessoryCircularView(entry: entry)
        case .accessoryInline: AccessoryInlineView(entry: entry)
        default: SmallUsageView(entry: entry, palette: palette)
        }
    }
}

/// The small family: one number worth crossing a room for, and the windows behind it while they
/// still fit. Everything past what fits is counted rather than dropped.
struct SmallUsageView: View {
    let entry: UsageEntry
    let palette: WidgetPalette

    private var glance: WidgetGlance { entry.glance }

    var body: some View {
        Group {
            if glance.isEmpty {
                EmptyUsageView()
            } else {
                ViewThatFits(in: .vertical) {
                    stack(extraRows: 2)
                    stack(extraRows: 1)
                    stack(extraRows: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .widgetURL(usageURL())
    }

    private func stack(extraRows: Int) -> some View {
        let hero = glance.hero
        let rest = Array(glance.rows.dropFirst(hero == nil ? 0 : 1))
        let extras = Array(rest.prefix(extraRows))
        return VStack(alignment: .leading, spacing: 5) {
            header(hidden: rest.count - extras.count)
            /// An account with one thing to say leaves slack; splitting it above and below keeps the
            /// hero in the tile rather than hanging it from the header.
            if extras.isEmpty { Spacer(minLength: 0) }
            if let hero {
                heroBlock(hero)
            }
            ForEach(extras) { row in
                QuotaRowView(
                    row: row, palette: palette, showsProvider: glance.providers.count > 1,
                    barHeight: 4, spacing: 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The count of what did not fit rides in the header rather than taking a line of its own — on
    /// this size a line spent saying "+2 more" is a window that could have been shown instead.
    private func header(hidden: Int) -> some View {
        HStack(spacing: 4) {
            Text(glance.title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if hidden > 0 {
                Text(verbatim: "+\(hidden)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(Text(String(localized: "\(hidden) more windows")))
            }
            Spacer(minLength: 2)
            FreshnessPill(
                freshness: glance.freshness, palette: palette,
                slug: glance.providers.first?.slug)
        }
    }

    private func heroBlock(_ hero: WidgetGlance.Row) -> some View {
        HStack(spacing: 8) {
            HeroValue(row: hero, palette: palette, size: 44, lineWidth: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(hero.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if glance.providers.count > 1 {
                    Text(hero.providerShort)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if entry.showsReset {
                    ResetClock(row: hero, asOf: entry.date, font: .system(size: 10))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hero.spoken)
    }
}

/// The medium family: the hero beside the rest of the account, which is the shape this size is
/// actually good at — one number to act on, and the context that says whether to act now.
struct MediumUsageView: View {
    let entry: UsageEntry
    let palette: WidgetPalette

    private var glance: WidgetGlance { entry.glance }

    var body: some View {
        Group {
            if glance.isEmpty {
                EmptyUsageView()
            } else {
                ViewThatFits(in: .vertical) {
                    layout(rows: 4, captions: showsCaptions)
                    layout(rows: 3, captions: false)
                    layout(rows: 2, captions: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .widgetURL(usageURL())
    }

    private var showsCaptions: Bool { glance.rows.contains { !$0.caption.isEmpty } }

    private func layout(rows maxRows: Int, captions: Bool) -> some View {
        let rows = Array(glance.rows.dropFirst(glance.hero == nil ? 0 : 1).prefix(maxRows))
        return VStack(alignment: .leading, spacing: 7) {
            header
            HStack(alignment: .top, spacing: 12) {
                if let hero = glance.hero {
                    heroColumn(hero)
                }
                if rows.isEmpty {
                    verdict
                } else {
                    QuotaRowGrid(
                        rows: rows, palette: palette, showsProvider: glance.providers.count > 1,
                        showsCaptions: captions)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(glance.title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(glance.verdict)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            FreshnessPill(
                freshness: glance.freshness, palette: palette, slug: glance.providers.first?.slug)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(glance.title). \(glance.verdict)")
    }

    private func heroColumn(_ hero: WidgetGlance.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HeroRing(row: hero, palette: palette, size: 62, lineWidth: 8)
            Text(
                glance.providers.count > 1
                    ? "\(hero.providerShort) · \(hero.shortLabel)" : hero.shortLabel
            )
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if entry.showsReset {
                ResetClock(row: hero, asOf: entry.date, font: .system(size: 10))
            }
        }
        .frame(width: 74, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hero.spoken)
    }

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(glance.verdict)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let hero = glance.hero, !hero.money.isEmpty {
                Text(hero.money)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The large family: every provider gets its own card, its own windows and the second line that says
/// what the money and the clock are doing.
struct LargeUsageView: View {
    let entry: UsageEntry
    let palette: WidgetPalette

    private var glance: WidgetGlance { entry.glance }

    var body: some View {
        Group {
            if glance.isEmpty {
                EmptyUsageView()
            } else {
                ViewThatFits(in: .vertical) {
                    stack(maxRows: 5, captions: true, hero: true)
                    stack(maxRows: 5, captions: true, hero: false)
                    stack(maxRows: 4, captions: true, hero: false)
                    stack(maxRows: 3, captions: true, hero: false)
                    stack(maxRows: 3, captions: false, hero: false)
                    stack(maxRows: 2, captions: false, hero: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .widgetURL(usageURL())
    }

    private func stack(maxRows: Int, captions: Bool, hero: Bool) -> some View {
        let shown = glance.providers.reduce(0) { $0 + min($1.rows.count, maxRows) }
        let hidden = glance.rows.count - shown
        return VStack(alignment: .leading, spacing: 9) {
            header
            /// An account with one provider leaves slack, and slack under the content reads as a
            /// widget that stopped early. Split it above and below instead, so what is there sits
            /// in the tile rather than hanging from its top edge.
            if glance.providers.count < 3 { Spacer(minLength: 0) }
            if hero, let row = glance.hero {
                heroBand(row)
            }
            ForEach(glance.providers) { provider in
                card(provider, maxRows: maxRows, captions: captions)
            }
            if hidden > 0 {
                Text(String(localized: "+\(hidden) more"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// What the account amounts to, above the cards that spell it out. It appears only where the
    /// cards leave room — an account with one provider has a hole this fills, and one with four has
    /// no room to spare.
    private func heroBand(_ row: WidgetGlance.Row) -> some View {
        HStack(spacing: 12) {
            HeroValue(row: row, palette: palette, size: 66, lineWidth: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(glance.verdict)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if !row.money.isEmpty {
                    Text(row.money)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if entry.showsReset {
                    ResetClock(row: row, asOf: entry.date)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(glance.verdict). \(row.spoken)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(String(localized: "Usage")).font(.headline.weight(.bold))
            Spacer(minLength: 4)
            Text(glance.freshness.note)
                .font(.caption2)
                .foregroundStyle(glance.freshness.isStale ? .secondary : .tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glance.verdict)
    }

    private func card(_ provider: WidgetGlance.Provider, maxRows: Int, captions: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(palette.identity(provider.slug)).frame(width: 7, height: 7)
                Text(provider.short).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !provider.subtitle.isEmpty {
                    Text(provider.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                if entry.showsReset, let top = provider.rows.first {
                    ResetClock(row: top, asOf: entry.date)
                }
            }
            QuotaRowGrid(
                rows: Array(provider.rows.prefix(maxRows)), palette: palette,
                showsCaptions: captions, abbreviated: false, barHeight: 7)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(palette.cardFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(palette.cardStroke), lineWidth: 0.5))
        }
    }
}

/// The Lock Screen accessories, which are drawn in one ink: every colour here is the platform's, and
/// the meaning has to survive in words, order and shape alone.
struct AccessoryRectangularView: View {
    let entry: UsageEntry

    var body: some View {
        let glance = entry.glance
        if glance.isEmpty {
            Text(WidgetGlance.emptyTitle).font(.caption2).foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .vertical) {
                rows(glance.rows(for: .rectangular))
                rows(Array(glance.rows.prefix(2)))
                rows(Array(glance.rows.prefix(1)))
            }
            .widgetURL(usageURL())
        }
    }

    private func rows(_ rows: [WidgetGlance.Row]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                HStack(spacing: 5) {
                    Text(label(row))
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if row.isCritical {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    }
                    Text(row.value)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let fraction = row.fraction {
                        GaugeBar(
                            fraction: fraction, color: .primary,
                            track: Color.primary.opacity(0.25)
                        )
                        .frame(width: 40, height: 4)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
            }
        }
    }

    private func label(_ row: WidgetGlance.Row) -> String {
        entry.glance.providers.count > 1 ? row.providerShort : row.shortLabel
    }
}

struct AccessoryCircularView: View {
    let entry: UsageEntry

    var body: some View {
        if let hero = entry.glance.hero {
            Gauge(value: hero.fraction ?? 1) {
                Text(hero.providerShort.prefix(1))
            } currentValueLabel: {
                if hero.kind == .balance {
                    Text(hero.value)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                } else if hero.tone == .danger {
                    Image(systemName: "exclamationmark.triangle.fill")
                } else {
                    Text("\(Int(((hero.fraction ?? 0) * 100).rounded()))")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .minimumScaleFactor(0.5)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .widgetURL(usageURL())
            .accessibilityLabel(hero.spoken)
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(WidgetGlance.emptyTitle)
        }
    }
}

struct AccessoryInlineView: View {
    let entry: UsageEntry

    var body: some View {
        let glance = entry.glance
        Label(
            glance.inlineText,
            systemImage: glance.hero?.tone == .danger
                ? "exclamationmark.triangle.fill"
                : (glance.isEmpty ? "gauge.with.dots.needle" : "gauge.with.needle")
        )
        .widgetURL(usageURL())
    }
}
