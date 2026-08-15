import AppIntents
import SwiftUI
import TailscodeCore
import WidgetKit

/// What one render of the Mac's Usage widget draws: the reading, already made, and the choices
/// somebody made in the widget's own editor. Nothing here asks a question — a widget is rendered at
/// a moment nobody chose, in a process with no window and no connection to lean on, so every
/// decision is taken before it arrives.
struct UsageEntry: TimelineEntry {
    let date: Date
    let glance: WidgetGlance
    let accent: WidgetAccentChoice
    let showsReset: Bool
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    /// Entries the widget moves through on its own — the countdown ticks and the reading ages
    /// without spending one of the day's few timeline reloads.
    private static let steps: [TimeInterval] = [0, 600, 1_200, 1_800]
    private static let refreshAfter: TimeInterval = 1_800
    /// A single reload fans out into one timeline call per family; the throttle collapses that
    /// burst into one trip to the machines.
    private static let refetchAfter: TimeInterval = 120

    func placeholder(in context: Context) -> UsageEntry {
        entry(from: UsageWidgetStore.previewEntry(), configuration: nil, at: Date())
    }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageEntry {
        let stored = UsageWidgetStore.read() ?? UsageWidgetStore.previewEntry()
        return entry(from: stored, configuration: configuration, at: Date())
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async
        -> Timeline<UsageEntry>
    {
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

    /// The extension keeps itself current inside its own budget rather than waiting for the app to
    /// be opened. A fetch that comes back with nothing — the tailnet is down, this build cannot
    /// reach the passwords — leaves the stored snapshot exactly where it was, which flips itself to
    /// CACHED on its own rather than turning the widget into an error message.
    private static func refreshLiveQuotas() async {
        if let stored = UsageWidgetStore.read(),
            Date().timeIntervalSince(stored.date) < refetchAfter
        {
            return
        }
        let quotas = await MacWidgetQuotas.fetch(deadline: 15)
        guard !quotas.isEmpty else { return }
        UsageWidgetStore.writeLive(quotas, reload: false)
    }
}

/// The families macOS actually offers a widget: the three system sizes, in Notification Centre and
/// on the desktop. There is no Lock Screen here, so there are no accessories to answer for.
struct MacUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: UsageWidgetStore.kind, intent: UsageWidgetIntent.self,
            provider: UsageTimelineProvider()
        ) { entry in
            MacUsageEntryView(entry: entry)
                .containerBackground(for: .widget) { MacBackdrop(entry: entry) }
        }
        .configurationDisplayName(String(localized: "Usage"))
        .description(
            String(localized: "Live agent spend and rate-limit quotas across your coding servers."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

func usageURL() -> URL { URL(string: "tailscode://usage")! }

private struct MacBackdrop: View {
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

struct MacUsageEntryView: View {
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
        case .systemMedium: MacMediumUsageView(entry: entry, palette: palette)
        case .systemLarge: MacLargeUsageView(entry: entry, palette: palette)
        default: MacSmallUsageView(entry: entry, palette: palette)
        }
    }
}

/// The small family: one number worth crossing a room for, and the windows behind it while they
/// still fit. Everything past what fits is counted rather than dropped.
struct MacSmallUsageView: View {
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
struct MacMediumUsageView: View {
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
                        showsCaptions: captions
                    )
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
struct MacLargeUsageView: View {
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
