import AppKit
import CodingAgentKit
import TailscodeCore

/// The shared vocabulary of quota rendering: severity thresholds, brand tints, countdowns and
/// money formatting — one place, so the sidebar footer and the popover can never disagree about
/// what 87% means.
@MainActor
enum UsageFormat {
    static func severity(_ fraction: Double) -> String {
        fraction > 0.85 ? "danger" : fraction >= 0.6 ? "warn" : "ok"
    }

    static func severityColor(_ severity: String) -> NSColor {
        switch severity {
        case "danger": return MacTheme.Color.danger
        case "warn": return MacTheme.Color.warning
        default: return MacTheme.Color.secondaryLabel
        }
    }

    static func brandColor(_ slug: String?) -> NSColor? {
        switch slug {
        case "claude": return MacTheme.Color.claude
        case "opencode": return MacTheme.Color.opencode
        case "grok":
            return NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.isDark
                        ? NSColor(white: 0.91, alpha: 1) : NSColor(white: 0.12, alpha: 1)
                })
        default: return nil
        }
    }

    /// The bar carries the severity, and only a healthy bar wears its provider's color — amber
    /// past 60%, red near the wall, exactly `ProviderBrand.fillClass`.
    static func fillColor(severity: String, slug: String?) -> NSColor {
        guard severity == "ok" else { return severityColor(severity) }
        return brandColor(slug) ?? MacTheme.Color.accent
    }

    static func gaugeBar(fraction: Double, width: CGFloat, height: CGFloat, fill: NSColor)
        -> NSView
    {
        let clamped = min(max(fraction, 0), 1)
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        track.layer?.cornerRadius = height / 2
        track.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = fill.cgColor
        bar.layer?.cornerRadius = height / 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(bar)
        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: width),
            track.heightAnchor.constraint(equalToConstant: height),
            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: (clamped * width).rounded()),
        ])
        return track
    }

    /// The hero's bar: as wide as whatever holds it, filled by proportion rather than by a fixed
    /// constant, on a visible track — the hero sits on a raised card, so a raised-coloured track
    /// would vanish into it.
    static func fullWidthBar(fraction: Double, height: CGFloat, fill: NSColor) -> NSView {
        let clamped = min(max(fraction, 0), 1)
        let track = NSView()
        track.wantsLayer = true
        track.layer?.backgroundColor = MacTheme.Color.separator.cgColor
        track.layer?.cornerRadius = height / 2
        track.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = fill.cgColor
        bar.layer?.cornerRadius = height / 2
        bar.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(bar)
        let proportional = bar.widthAnchor.constraint(
            equalTo: track.widthAnchor, multiplier: clamped)
        proportional.priority = .defaultHigh
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: height),
            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor),
            bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            proportional,
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: height),
        ])
        return track
    }

    /// A spend window reads as money, everything else as the percent already used — or "Used up"
    /// when the window is at the wall.
    static func amount(for gauge: UsageQuota.Gauge) -> String {
        if let used = gauge.usedUSD, let limit = gauge.limitUSD {
            return "$\(trimmed(used)) of $\(trimmed(limit))"
        }
        let percent = "\(Int((min(max(gauge.fraction, 0), 1) * 100).rounded()))%"
        return QuotaSurface.amountLabel(fraction: gauge.fraction, percentText: percent)
    }

    static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func countdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return Localized.text("moments") }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Quota as a glance in the sidebar footer, the way the Linux desktop keeps it: one thin bar per
/// gauge, the number beside it, the reset countdown only under a row that is actually close to
/// resetting. Transparent over the sidebar material — the glass is the only background.
@MainActor
final class UsageFooterView: NSView {
    private let column = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(_ quotas: [(String, UsageQuota)]) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let holdings = QuotaRollup.account(from: quotas)
        isHidden = holdings.isEmpty
        for holding in holdings {
            let slug = holding.slug
            let header = RowKit.label(
                holding.providerName,
                font: MacTheme.Ramp.font(.metricLabel),
                color: UsageFormat.brandColor(slug) ?? MacTheme.Color.secondaryLabel)
            column.addArrangedSubview(header)
            column.setCustomSpacing(5, after: header)
            for gauge in holding.gauges {
                let fraction = min(max(gauge.fraction, 0), 1)
                let severity = UsageFormat.severity(fraction)
                let color = UsageFormat.severityColor(severity)

                let title = RowKit.label(gauge.label, font: MacTheme.Ramp.font(.panelFootnote), color: color)
                title.setContentCompressionResistancePriority(.init(200), for: .horizontal)
                let percent = RowKit.label(
                    UsageFormat.amount(for: gauge), font: MacTheme.Ramp.font(.panelFootnote),
                    color: color)
                percent.alignment = .right
                percent.widthAnchor.constraint(equalToConstant: 34).isActive = true
                let row = NSStackView(views: [
                    title, RowKit.spacer(),
                    UsageFormat.gaugeBar(
                        fraction: fraction, width: 72, height: 5,
                        fill: UsageFormat.fillColor(severity: severity, slug: slug)),
                    percent,
                ])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = MacTheme.Spacing.s
                column.addArrangedSubview(row)

                if let resets = gauge.resetsAt, gauge.trustedReset, fraction >= 0.6 {
                    column.addArrangedSubview(
                        RowKit.label(
                            Localized.text("resets in %@", UsageFormat.countdown(to: resets)),
                            font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
                }
            }
            if let last = column.arrangedSubviews.last {
                column.setCustomSpacing(MacTheme.Spacing.s, after: last)
            }
        }
    }
}

/// The full quota picture behind the toolbar gauge: one card per provider, every gauge as a wide
/// bar with its reset, spend windows in money, and the account facts the provider reports. Opens
/// on what the footer already knows, then refetches so the numbers are current; the refresh
/// button asks again. Popover chrome is the system material — content, not floating glass.
@MainActor
final class UsagePanelViewController: NSViewController {
    private let column = NSStackView()
    private var quotas: [(String, UsageQuota)]
    private let refresh: () async -> [(String, UsageQuota)]
    private let onAnalytics: () -> Void
    private var refreshing = false

    init(
        initial: [(String, UsageQuota)],
        refresh: @escaping () async -> [(String, UsageQuota)],
        onAnalytics: @escaping () -> Void
    ) {
        self.quotas = initial
        self.refresh = refresh
        self.onAnalytics = onAnalytics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        let scroll = NSScrollView()
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        let refreshButton = RowKit.ActionButton(title: Localized.text("Refresh")) { [weak self] in
            self?.startRefresh()
        }
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        let monthButton = RowKit.ActionButton(title: Localized.text("The month in numbers")) {
            [weak self] in
            self?.onAnalytics()
        }
        monthButton.isBordered = false
        monthButton.contentTintColor = MacTheme.Color.accent
        monthButton.controlSize = .small
        let footer = NSStackView(views: [monthButton, RowKit.spacer(), refreshButton])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(
            top: 0, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [scroll, footer])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = MacTheme.Spacing.s
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 372),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        view = container
        renderCards()
        startRefresh()
    }

    private func startRefresh() {
        guard !refreshing else { return }
        refreshing = true
        renderCards()
        Task { [weak self] in
            guard let self else { return }
            let fresh = await self.refresh()
            if !fresh.isEmpty { self.quotas = fresh }
            self.refreshing = false
            self.renderCards()
        }
    }

    private func renderCards() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if quotas.isEmpty {
            column.addArrangedSubview(
                RowKit.label(
                    refreshing
                        ? Localized.text("Asking the providers…")
                        : Localized.text("No provider reports a quota."),
                    font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.secondaryLabel))
            return
        }
        let holdings = QuotaRollup.account(from: quotas)
        if let hero = heroCard(holdings) {
            column.addArrangedSubview(hero)
        }
        for holding in holdings {
            column.addArrangedSubview(card(holding))
        }
        if refreshing {
            column.addArrangedSubview(
                RowKit.label(
                    Localized.text("Refreshing…"), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
    }

    /// The panel leads with the tightest window across every provider — the one that decides
    /// when the next send unlocks — as one big bar with its countdown. The cards below carry
    /// the rest.
    private func heroCard(_ holdings: [QuotaHolding]) -> NSView? {
        guard let (holding, gauge) = QuotaRollup.tightest(in: holdings) else { return nil }
        let quota = holding.quota
        let slug = holding.slug
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = UsageFormat.severity(fraction)

        let caption = RowKit.label(
            Localized.text("Tightest window"), font: MacTheme.Ramp.font(.metricLabel),
            color: MacTheme.Color.tertiaryLabel)
        let name = RowKit.label(
            "\(quota.providerName) · \(gauge.label)", font: MacTheme.Ramp.font(.cardTitle),
            color: UsageFormat.brandColor(slug) ?? MacTheme.Color.label)
        name.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let amount = RowKit.label(
            UsageFormat.amount(for: gauge),
            font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
            color: severity == "ok"
                ? MacTheme.Color.label : UsageFormat.severityColor(severity))
        amount.setContentHuggingPriority(.required, for: .horizontal)
        let nameRow = NSStackView(views: [name, RowKit.spacer(), amount])
        nameRow.orientation = .horizontal
        nameRow.alignment = .firstBaseline
        nameRow.spacing = MacTheme.Spacing.s

        let bar = UsageFormat.fullWidthBar(
            fraction: fraction, height: 9,
            fill: UsageFormat.fillColor(severity: severity, slug: slug))

        var views: [NSView] = [caption, nameRow, bar]
        if let resets = gauge.resetsAt {
            let phrasing =
                gauge.trustedReset
                ? Localized.text("resets in %@", UsageFormat.countdown(to: resets))
                : Localized.text("resets in about %@", UsageFormat.countdown(to: resets))
            views.append(
                RowKit.label(
                    phrasing, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
        let hero = NSStackView(views: views)
        hero.orientation = .vertical
        hero.alignment = .width
        hero.spacing = MacTheme.Spacing.s
        hero.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        hero.wantsLayer = true
        hero.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        hero.layer?.cornerRadius = MacTheme.Radius.control
        hero.translatesAutoresizingMaskIntoConstraints = false
        return hero
    }

    private func card(_ holding: QuotaHolding) -> NSView {
        let quota = holding.quota
        let slug = holding.slug
        let card = NSStackView()
        card.orientation = .vertical
        card.alignment = .width
        card.spacing = MacTheme.Spacing.s
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.wantsLayer = true
        card.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        card.layer?.cornerRadius = MacTheme.Radius.control
        card.translatesAutoresizingMaskIntoConstraints = false

        let name = RowKit.label(
            quota.providerName, font: MacTheme.Ramp.font(.panelTitle),
            color: UsageFormat.brandColor(slug) ?? MacTheme.Color.label)
        let header = NSStackView(views: [name])
        if !quota.subtitle.isEmpty {
            header.addArrangedSubview(
                RowKit.label(
                    quota.subtitle, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel))
        }
        header.addArrangedSubview(RowKit.spacer())
        header.addArrangedSubview(Self.badge(live: quota.live))
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(header)

        for gauge in quota.gauges {
            card.addArrangedSubview(Self.gaugeBlock(gauge, slug: slug))
        }

        if !quota.details.isEmpty {
            card.addArrangedSubview(RowKit.hairline())
            for detail in quota.details {
                let key = RowKit.label(
                    detail.key, font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.secondaryLabel)
                let value = RowKit.label(
                    detail.value, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
                let row = NSStackView(views: [key, RowKit.spacer(), value])
                row.orientation = .horizontal
                row.spacing = MacTheme.Spacing.s
                card.addArrangedSubview(row)
            }
        }

        card.addArrangedSubview(
            RowKit.label(
                QuotaRollup.provenance(holding), font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.tertiaryLabel))
        return card
    }

    private static func gaugeBlock(_ gauge: UsageQuota.Gauge, slug: String?) -> NSView {
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = UsageFormat.severity(fraction)
        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .width
        block.spacing = 3

        let title = RowKit.label(
            gauge.label, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let amount = RowKit.label(
            UsageFormat.amount(for: gauge), font: MacTheme.Ramp.font(.panelFootnote),
            color: UsageFormat.severityColor(severity))
        let row = NSStackView(views: [title, RowKit.spacer(), amount])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        block.addArrangedSubview(row)

        let bar = UsageFormat.gaugeBar(
            fraction: fraction, width: 300, height: 6,
            fill: UsageFormat.fillColor(severity: severity, slug: slug))
        let barRow = NSStackView(views: [bar, RowKit.spacer()])
        barRow.orientation = .horizontal
        block.addArrangedSubview(barRow)

        if let resets = gauge.resetsAt {
            let phrasing =
                gauge.trustedReset
                ? Localized.text("resets in %@", UsageFormat.countdown(to: resets))
                : Localized.text("resets in about %@", UsageFormat.countdown(to: resets))
            block.addArrangedSubview(
                RowKit.label(
                    phrasing, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel))
        }
        return block
    }

    private static func badge(live: Bool) -> NSView {
        let label = NSTextField(
            labelWithString: live ? Localized.text("LIVE") : Localized.text("CACHED"))
        label.font = MacTheme.Ramp.font(.metricLabel)
        label.textColor = live ? MacTheme.Color.success : MacTheme.Color.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 4
        wrap.layer?.backgroundColor =
            (live
                ? MacTheme.Color.success.withAlphaComponent(0.15)
                : MacTheme.Color.canvasRaised).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }
}
