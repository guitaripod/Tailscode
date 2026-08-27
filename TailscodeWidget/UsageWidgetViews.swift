import SwiftUI
import TailscodeCore
import WidgetKit

extension Color {
    /// A colour from the six-digit hex a palette is written in, through the same channel reader the
    /// contrast arithmetic uses — so a widget and the app it belongs to draw the identical slot.
    init?(hex: String) {
        guard let channels = Contrast.channels(hex) else { return nil }
        self.init(
            .sRGB, red: Double(channels.red), green: Double(channels.green),
            blue: Double(channels.blue), opacity: 1)
    }
}

/// The agents' own colours where no theme is chosen — the same values every palette publishes
/// before correction, so "System" looks like Tailscode rather than like nothing.
private enum WidgetBrand {
    static func color(_ slug: String?, dark: Bool) -> Color? {
        switch slug {
        case "claude": return Color(hex: "#d97757")
        case "opencode": return Color(hex: "#03b000")
        case "grok": return Color(hex: dark ? "#e8e8eb" : "#1f1f1f")
        case "deepseek": return Color(hex: "#4d6bfe")
        case "ollama-cloud": return Color(hex: dark ? "#f0f0f0" : "#1a1a1a")
        default: return nil
        }
    }
}

/// Where every pixel of colour in a widget comes from, resolved once per render.
///
/// Three things decide it and nothing else: which theme the app is wearing (read from the mirror in
/// the app group, because an extension cannot see the app's own defaults), which colour source the
/// person picked for this widget, and the rendering mode the system handed down. The last one wins
/// outright — a tinted or Lock Screen widget is drawn in one ink by the platform, and a palette that
/// insisted on itself there would simply vanish.
struct WidgetPalette {
    let palette: Palette?
    let dark: Bool
    let mode: WidgetRenderingMode
    let choice: WidgetAccentChoice

    static func resolve(choice: WidgetAccentChoice, dark: Bool, mode: WidgetRenderingMode)
        -> WidgetPalette
    {
        let stored = ThemeSelection.mirrored(suiteName: UsageWidgetStore.suiteName)
        let face = stored.appearance.pinnedDark ?? dark
        let palette: Palette? =
            (choice == .theme && stored.themeID != ThemeSelection.systemID)
            ? ThemeSelection.palette(themeID: stored.themeID, dark: face) : nil
        return WidgetPalette(palette: palette, dark: face, mode: mode, choice: choice)
    }

    var isFullColor: Bool { mode == .fullColor }
    /// A card needs a stronger fill under accenting, where a material would be flattened away.
    var cardFill: Double { mode == .accented ? 0.16 : 0.07 }
    var cardStroke: Double { mode == .accented ? 0.32 : 0.10 }
    var track: Color { Color.primary.opacity(mode == .fullColor ? 0.13 : 0.22) }

    /// The colour a row is drawn in: its meaning first, its brand second. A wall is the failure
    /// colour whatever else was chosen, because a person reading red is reading "stop", and a widget
    /// that spent that colour on a provider's branding would have nothing left to say it with.
    func color(_ tone: WidgetGlance.Tone, slug: String?) -> Color {
        guard isFullColor, choice != .monochrome else { return .primary }
        switch tone {
        case .danger: return slot(\.danger, fallback: .red)
        case .warn: return slot(\.warn, fallback: .orange)
        case .balance:
            return choice == .provider ? (brand(slug) ?? slot(\.info, fallback: .blue))
                : slot(\.info, fallback: .blue)
        case .ok:
            return choice == .provider ? (brand(slug) ?? slot(\.accent, fallback: .teal))
                : slot(\.accent, fallback: .teal)
        case .quiet: return .secondary
        }
    }

    /// A provider's identity mark, which stays its own colour at every level of fullness — the dot
    /// beside a name is saying who, not how much. It keeps the brand even where the rows are drawn
    /// in one theme colour, because telling two providers apart is the only job it has.
    func identity(_ slug: String?) -> Color {
        guard isFullColor, choice != .monochrome else { return .primary }
        return brand(slug) ?? slot(\.accent, fallback: .teal)
    }

    /// The wash behind the whole widget: the leading provider's colour, barely there.
    func backdrop(_ slug: String?) -> Color {
        guard isFullColor else { return .clear }
        return brand(slug) ?? slot(\.accent, fallback: .teal)
    }

    var canvas: Color {
        guard let palette, isFullColor, let color = Color(hex: palette.canvas) else {
            return Color(.systemBackground)
        }
        return color
    }

    /// A provider's own colour, corrected by the theme where one is on so it stays readable on that
    /// theme's canvas, and the published brand where the platform's colours are in force.
    private func brand(_ slug: String?) -> Color? {
        guard let palette else { return WidgetBrand.color(slug, dark: dark) }
        switch slug {
        case "claude": return Color(hex: palette.brandClaude)
        case "opencode": return Color(hex: palette.brandOpencode)
        case "grok": return Color(hex: palette.brandGrok)
        case "deepseek": return Color(hex: palette.brandDeepseek)
        case "ollama-cloud": return Color(hex: palette.brandOllama)
        default: return nil
        }
    }

    private func slot(_ key: KeyPath<Palette, String>, fallback: Color) -> Color {
        guard let palette, let color = Color(hex: palette[keyPath: key]) else { return fallback }
        return color
    }
}

/// The bar a window's fullness fills. A window with almost nothing spent still shows a sliver, so a
/// row never reads as a missing bar; a wall fills it outright.
struct GaugeBar: View {
    let fraction: Double
    let color: Color
    var track: Color = Color.primary.opacity(0.13)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0.035, fraction))))
            }
        }
    }
}

/// The tightest window as one number big enough to read across a room: the ring, what it meters, and
/// the clock that ends it. A balance has no ceiling, so it has no ring — a filled circle beside
/// money would be claiming a fullness nobody measured.
struct HeroValue: View {
    let row: WidgetGlance.Row
    let palette: WidgetPalette
    let size: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        if row.fraction == nil {
            HStack(spacing: 5) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: size * 0.2))
                Text(row.value)
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .foregroundStyle(palette.color(row.tone, slug: row.slug))
            .frame(minHeight: size, alignment: .leading)
            .accessibilityHidden(true)
        } else {
            HeroRing(row: row, palette: palette, size: size, lineWidth: lineWidth)
        }
    }
}

struct HeroRing: View {
    let row: WidgetGlance.Row
    let palette: WidgetPalette
    let size: CGFloat
    let lineWidth: CGFloat

    private var color: Color { palette.color(row.tone, slug: row.slug) }
    private var trimmed: CGFloat { CGFloat(min(1, max(0.02, row.fraction ?? 1))) }

    var body: some View {
        ZStack {
            Circle().stroke(palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: trimmed)
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(row.value)
                .font(.system(size: size * (row.kind == .balance ? 0.20 : 0.27), weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, lineWidth)
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var stroke: AnyShapeStyle {
        guard palette.isFullColor else { return AnyShapeStyle(color) }
        return AnyShapeStyle(
            AngularGradient(
                gradient: Gradient(colors: [color.opacity(0.7), color]),
                center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)))
    }
}

/// One window as a line: what it is, how full, and the number. The bar carries the fullness and the
/// number carries the fact, so neither has to be read to get the other.
struct QuotaRowView: View {
    let row: WidgetGlance.Row
    let palette: WidgetPalette
    var showsProvider = false
    var showsCaption = false
    var barHeight: CGFloat = 6
    var spacing: CGFloat = 3

    private var color: Color { palette.color(row.tone, slug: row.slug) }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 5) {
                Circle().fill(palette.identity(row.slug)).frame(width: 5, height: 5)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if row.isCritical { SeverityGlyph(size: 8) }
                Text(row.value)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(color)
            }
            if let fraction = row.fraction {
                GaugeBar(fraction: fraction, color: color, track: palette.track)
                    .frame(height: barHeight)
            }
            if showsCaption, !row.caption.isEmpty {
                Text(row.caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
    }

    private var label: String {
        guard showsProvider else { return row.shortLabel }
        return "\(row.providerShort) · \(row.shortLabel)"
    }
}

/// The same row where the columns can be shared across a table: label, bar and number line up down
/// the widget instead of each row measuring its own.
struct QuotaRowGrid: View {
    let rows: [WidgetGlance.Row]
    let palette: WidgetPalette
    var showsProvider = false
    var showsCaptions = false
    var abbreviated = true
    var barHeight: CGFloat = 6

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            ForEach(rows) { row in
                let color = palette.color(row.tone, slug: row.slug)
                GridRow {
                    Text(label(row))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .gridColumnAlignment(.leading)
                    Group {
                        if let fraction = row.fraction {
                            GaugeBar(fraction: fraction, color: color, track: palette.track)
                                .frame(height: barHeight)
                        } else if !abbreviated {
                            /// A balance has no bar, so the column its bar would have taken says
                            /// what the money is made of — but only where the column is wide
                            /// enough to finish the sentence.
                            Text(row.caption)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Color.clear.frame(height: barHeight)
                        }
                    }
                    HStack(spacing: 2) {
                        if row.isCritical { SeverityGlyph(size: 8) }
                        Text(row.value)
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(color)
                    }
                    .gridColumnAlignment(.trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
                if showsCaptions, !row.caption.isEmpty, row.fraction != nil {
                    GridRow {
                        Text(row.caption)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .gridCellColumns(3)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func label(_ row: WidgetGlance.Row) -> String {
        let window = abbreviated ? row.shortLabel : row.label
        return showsProvider ? "\(row.providerShort) · \(window)" : window
    }
}

/// The clock on the window that decides the next send. Under an hour it ticks by itself, because a
/// countdown that is about to matter is worth the system drawing it; past that it is a fact in words
/// and re-rendering it every minute would spend a refresh on nothing.
struct ResetClock: View {
    let row: WidgetGlance.Row
    let asOf: Date
    var font: Font = .caption2

    var body: some View {
        if let resetsAt = row.resetsAt, resetsAt > asOf {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                if resetsAt.timeIntervalSince(asOf) < 3_600 {
                    Text(
                        timerInterval: asOf...resetsAt, pauseTime: nil, countsDown: true,
                        showsHours: false
                    )
                    .monospacedDigit()
                } else {
                    Text(QuotaSurface.countdown(to: resetsAt, now: asOf)).monospacedDigit()
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel(Text(Localized.text("resets in %@", QuotaSurface.countdown(to: resetsAt, now: asOf))))
        }
    }
}

/// Where the numbers came from, in the one word every client uses for it. Stale says so first,
/// because a percentage nobody could refresh presented as current is the one lie a widget can tell.
struct FreshnessPill: View {
    let freshness: WidgetGlance.Freshness
    let palette: WidgetPalette
    let slug: String?

    private var tint: Color { freshness.isStale ? .secondary : palette.identity(slug) }

    var body: some View {
        HStack(spacing: 3) {
            Text(freshness.badge)
                .font(.system(size: 8.5, weight: .heavy))
                .lineLimit(1)
            if !freshness.isStale {
                Circle().fill(palette.isFullColor ? Color.green : Color.primary)
                    .frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityLabel(freshness.note.isEmpty ? freshness.badge : freshness.note)
    }
}

struct SeverityGlyph: View {
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size))
            .foregroundStyle(.red)
            .accessibilityHidden(true)
    }
}

struct EmptyUsageView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(WidgetGlance.emptyTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(WidgetGlance.emptyDetail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The wash the whole widget sits on: the leading provider's colour at the corner it reads from.
struct ContainerBackdrop: View {
    let glance: WidgetGlance
    let palette: WidgetPalette

    var body: some View {
        ZStack {
            palette.canvas
            if let provider = glance.providers.first {
                let accent = palette.backdrop(provider.slug)
                LinearGradient(
                    colors: [accent.opacity(0.22), accent.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}
