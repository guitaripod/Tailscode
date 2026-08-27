import AppKit
import CodingAgentKit
import CodingAgentKitApple
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

    /// The strip's tones, which are meanings rather than severities: relief is the accent, money
    /// is ordinary ink, and a sentence about the reading is quieter than the numbers it qualifies.
    static func glanceColor(_ tone: QuotaGlance.Tone) -> NSColor {
        switch tone {
        case .danger: return MacTheme.Color.danger
        case .warn: return MacTheme.Color.warning
        case .ok: return MacTheme.Color.accent
        case .balance: return MacTheme.Color.label
        case .quiet: return MacTheme.Color.secondaryLabel
        }
    }

    static func brandColor(_ slug: String?) -> NSColor? {
        switch slug {
        case "claude": return MacTheme.Color.claude
        case "opencode": return MacTheme.Color.opencode
        case "grok":
            return ThemePalette.color(
                \.brandGrok,
                system: NSColor(
                    name: nil,
                    dynamicProvider: { appearance in
                        appearance.isDark
                            ? NSColor(white: 0.91, alpha: 1) : NSColor(white: 0.12, alpha: 1)
                    }))
        case "ollama-cloud":
            return ThemePalette.color(
                \.brandOllama,
                system: NSColor(
                    name: nil,
                    dynamicProvider: { appearance in
                        appearance.isDark
                            ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.10, alpha: 1)
                    }))
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

    /// Money without a ceiling is a prepaid balance rather than a window: nothing fills, nothing
    /// resets, and the only cap anyone could draw would be invented.
    static func isBalance(_ gauge: UsageQuota.Gauge) -> Bool {
        gauge.usedUSD != nil && gauge.limitUSD == nil
    }

    /// A spend window reads as money, a balance as the money itself, and everything else as the
    /// percent already used — or "Used up" when the window is at the wall.
    static func amount(for gauge: UsageQuota.Gauge) -> String {
        if let used = gauge.usedUSD, let limit = gauge.limitUSD {
            return Localized.text(
                "%@ of %@", QuotaGlance.money(used, gauge.currency),
                QuotaGlance.money(limit, gauge.currency))
        }
        if isBalance(gauge) { return DeepSeekBalance.amount(for: gauge) }
        let percent = "\(Int((min(max(gauge.fraction, 0), 1) * 100).rounded()))%"
        return QuotaSurface.amountLabel(fraction: gauge.fraction, percentText: percent)
    }

    /// The ink a balance's number wears: ordinary label ink, because money in hand is a fact
    /// rather than a severity — and the failure colour at zero, which is the one wall a balance
    /// can hit.
    static func balanceColor(_ gauge: UsageQuota.Gauge) -> NSColor {
        gauge.fraction >= QuotaSurface.exhaustedFloor
            ? MacTheme.Color.danger : MacTheme.Color.label
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
    private let column = FillingStack()
    private var last: ([(String, UsageQuota)], Date?) = ([], nil)
    private var probing = false
    private var probingOllama = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: DeepSeekBalance.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: OllamaUsage.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A theme reaches an `NSColor` on its own, but never a `CGColor` already in a bar's layer —
    /// and the window's restyle rebuilds the rows above this strip without coming through here. So
    /// the strip draws itself again from the reading it already had, rather than wearing the last
    /// theme's ink until the next usage tick.
    @objc private func repaint() {
        render(last.0, answeredAt: last.1)
    }

    func render(_ quotas: [(String, UsageQuota)], answeredAt: Date?) {
        last = (quotas, answeredAt)
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var folded = DeepSeekBalance.folded(into: quotas)
        if let reading = OllamaUsage.cached {
            folded = folded + [("", OllamaCloud.snapshot(for: reading))]
        }
        let glance = QuotaGlance.make(from: folded, answeredAt: answeredAt)
        isHidden = glance.isEmpty
        toolTip = glance.tooltip.isEmpty ? nil : glance.tooltip
        for line in glance.lines {
            column.addArrangedSubview(row(line))
        }
        probeBalance()
        probeOllama()
    }

    /// The cloud plan's windows ride the strip's own cadence too: no server holds them, so they
    /// are asked for where they are drawn, and only a changed reading redraws the strip.
    private func probeOllama() {
        guard !probingOllama else { return }
        probingOllama = true
        let drawn = OllamaUsage.cached
        Task { [weak self] in
            let reading = await OllamaUsage.refresh()
            guard let self else { return }
            self.probingOllama = false
            guard reading != drawn else { return }
            self.render(self.last.0, answeredAt: self.last.1)
        }
    }

    /// The prepaid balance rides the strip's own cadence: no server holds it, so it is asked for
    /// where it is drawn. The ask is throttled inside `DeepSeekBalance`, costs nothing without a
    /// key, and only redraws the strip when the money actually moved — a repaint per poll of an
    /// unchanged number is motion the reader would have to read.
    private func probeBalance() {
        guard !probing else { return }
        probing = true
        let drawn = DeepSeekBalance.cached
        Task { [weak self] in
            let reading = await DeepSeekBalance.refresh()
            guard let self else { return }
            self.probing = false
            guard reading != drawn else { return }
            self.render(self.last.0, answeredAt: self.last.1)
        }
    }

    /// One line, three columns: the tone dot, the words, and the number the words are about —
    /// right-aligned in a column of its own width so the strip reads down rather than across. A
    /// sentence about the reading itself wears no dot and starts where the words start.
    private func row(_ line: QuotaGlance.Line) -> NSView {
        let color = UsageFormat.glanceColor(line.tone)
        if line.kind == .notice {
            let text = RowKit.label(
                line.text, font: MacTheme.Ramp.font(.panelFootnote), color: color)
            let row = NSStackView(views: [text, RowKit.spacer()])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = MacTheme.Spacing.s
            row.edgeInsets = NSEdgeInsets(top: 0, left: Self.textIndent, bottom: 0, right: 0)
            return row
        }

        let dot = RowKit.label(
            "●", font: MacTheme.Ramp.font(.gaugeCaption),
            color: line.tone == .balance
                ? (UsageFormat.brandColor(line.slug) ?? color) : color)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        let text = RowKit.label(
            line.text, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
        text.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        var views: [NSView] = [dot, text, RowKit.spacer()]
        if let fraction = line.fraction {
            views.append(
                UsageFormat.gaugeBar(
                    fraction: fraction, width: 44, height: 4,
                    fill: UsageFormat.fillColor(
                        severity: UsageFormat.severity(fraction), slug: line.slug)))
        }
        if !line.trailing.isEmpty {
            let value = RowKit.label(
                line.trailing, font: MacTheme.Ramp.font(.gauge), color: color)
            value.alignment = .right
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            value.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 62 * MacTheme.UIScale.factor).isActive = true
            views.append(value)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.xs
        return row
    }

    /// Where the words start on a line that carries no dot. The column it has to meet is one glyph
    /// of a font that grows with the type scale, so the indent is measured off that glyph rather
    /// than kept as a constant that only lines up at one size.
    private static var textIndent: CGFloat {
        let dot = RowKit.label(
            "●", font: MacTheme.Ramp.font(.gaugeCaption), color: MacTheme.Color.label)
        return dot.intrinsicContentSize.width + MacTheme.Spacing.xs
    }
}

/// The full quota picture behind the toolbar gauge: one card per provider, every gauge as a wide
/// bar with its reset, spend windows in money, and the account facts the provider reports. Opens
/// on what the footer already knows, then refetches so the numbers are current; the refresh
/// button asks again. Popover chrome is the system material — content, not floating glass.
@MainActor
final class UsagePanelViewController: NSViewController {
    private let column = FillingStack()
    private var quotas: [(String, UsageQuota)]
    private let refresh: () async -> [(String, UsageQuota)]
    private let onAnalytics: () -> Void
    private var refreshing = false
    /// The prepaid balance is this Mac's own reading rather than a server's report, so it is held
    /// beside the servers' quotas and folded in only where the cards are built.
    private var balance: DeepSeekBalance.Reading?

    init(
        initial: [(String, UsageQuota)],
        refresh: @escaping () async -> [(String, UsageQuota)],
        onAnalytics: @escaping () -> Void
    ) {
        self.quotas = initial
        self.refresh = refresh
        self.onAnalytics = onAnalytics
        self.balance = DeepSeekBalance.cached
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
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

        let content = FillingStack(views: [scroll, footer])
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
            let reading = await DeepSeekBalance.refresh()
            self.balance = reading ?? DeepSeekBalance.cached
            await OllamaUsage.refresh()
            self.refreshing = false
            self.renderCards()
        }
    }

    private func renderCards() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let holdings = QuotaRollup.account(from: reports())
        if holdings.isEmpty {
            column.addArrangedSubview(
                RowKit.label(
                    refreshing
                        ? Localized.text("Asking the providers…")
                        : Localized.text("No provider reports a quota."),
                    font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.secondaryLabel))
        } else {
            if let hero = heroCard(holdings) {
                column.addArrangedSubview(hero)
            }
            for holding in holdings {
                column.addArrangedSubview(card(holding))
            }
        }
        if let invitation = deepseekCard() {
            column.addArrangedSubview(invitation)
        }
        if refreshing {
            column.addArrangedSubview(
                RowKit.label(
                    Localized.text("Refreshing…"), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
    }

    private func reports() -> [(String, UsageQuota)] {
        var reports = quotas
        if let balance {
            reports = reports + [("", DeepSeekBalance.snapshot(for: balance))]
        }
        if let reading = OllamaUsage.cached {
            reports = reports + [("", OllamaCloud.snapshot(for: reading))]
        }
        return reports
    }

    /// What the panel says about DeepSeek when there is no balance to draw: a key nobody has set
    /// is a state with words and one action rather than a blank space, and a key that has been set
    /// but not yet answered for says exactly that instead of reading as an account with no money.
    /// It is offered only where it could matter — an opencode server is what fronts these models —
    /// so an account that has never touched DeepSeek is not told about one.
    private func deepseekCard() -> NSView? {
        guard balance == nil else { return nil }
        let hasKey = DeepSeekCredentials.hasToken
        let fronted = ServerDirectory.shared.profiles.contains { $0.backend == .openCode }
        guard hasKey || fronted else { return nil }

        let words =
            hasKey
            ? Localized.text(
                "The key is set and api.deepseek.com has not answered yet — the prepaid balance appears here as soon as it does.")
            : Localized.text(
                "DeepSeek models billed straight to your own platform account are metered by a prepaid balance rather than by a plan. Add the key and the balance joins these numbers.")
        let action =
            hasKey ? Localized.text("Edit key…") : Localized.text("Add key…")

        let card = FillingStack()
        card.spacing = MacTheme.Spacing.s
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.wantsLayer = true
        card.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        card.layer?.cornerRadius = MacTheme.Radius.control
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addArrangedSubview(
            RowKit.label(
                Localized.text("DeepSeek"), font: MacTheme.Ramp.font(.panelTitle),
                color: MacTheme.Color.label))
        card.addArrangedSubview(
            RowKit.wrapping(
                words, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel))
        let button = RowKit.ActionButton(title: action) { [weak self] in
            self?.editDeepSeekKey()
        }
        button.controlSize = .small
        let row = NSStackView(views: [button, RowKit.spacer()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(row)
        return card
    }

    /// The editor is sheeted on the app's own window rather than on the popover, which is
    /// transient: a sheet hung off a window that closes the moment the keyboard moves is a sheet
    /// that vanishes mid-paste.
    private func editDeepSeekKey() {
        DeepSeekKeySheet.present(on: NSApp?.mainWindow) { [weak self] in
            guard let self else { return }
            self.balance = DeepSeekBalance.cached
            self.renderCards()
            self.startRefresh()
        }
    }

    /// The panel leads with the tightest window across every provider — the one that decides
    /// when the next send unlocks — as one big bar with its countdown. The cards below carry
    /// the rest.
    private func heroCard(_ holdings: [QuotaHolding]) -> NSView? {
        guard let (holding, gauge) = QuotaRollup.tightest(in: Self.windowsOnly(holdings))
        else { return nil }
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
            font: MacTheme.Ramp.font(.metricLarge),
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
        let hero = FillingStack(views: views)
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

    /// A balance never leads. The hero is the window that decides when the next send unlocks, and
    /// a prepaid balance is neither a window nor a countdown — an empty one would otherwise take
    /// the top of the panel wearing "Tightest window" over money that resets on nothing.
    private static func windowsOnly(_ holdings: [QuotaHolding]) -> [QuotaHolding] {
        holdings.compactMap { holding -> QuotaHolding? in
            var quota = holding.quota
            quota.gauges = quota.gauges.filter { !UsageFormat.isBalance($0) }
            guard !quota.gauges.isEmpty else { return nil }
            return QuotaHolding(quota: quota, machines: holding.machines)
        }
    }

    private func card(_ holding: QuotaHolding) -> NSView {
        let quota = holding.quota
        let slug = holding.slug
        let card = FillingStack()
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
        header.addArrangedSubview(Self.badge(for: quota))
        header.orientation = .horizontal
        header.alignment = .centerY
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

    /// One gauge, and one exception to it: money with no ceiling is drawn as the number itself.
    /// A bar under a balance would have to invent the cap it fills against, and the card's own
    /// details already say what the money is made of — topped up, and granted.
    private static func gaugeBlock(_ gauge: UsageQuota.Gauge, slug: String?) -> NSView {
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = UsageFormat.severity(fraction)
        let isBalance = UsageFormat.isBalance(gauge)
        let block = FillingStack()
        block.spacing = 3

        let title = RowKit.label(
            gauge.label, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
        title.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let amount = RowKit.label(
            UsageFormat.amount(for: gauge),
            font: MacTheme.Ramp.font(isBalance ? .metricValue : .panelFootnote),
            color: isBalance
                ? UsageFormat.balanceColor(gauge) : UsageFormat.severityColor(severity))
        let row = NSStackView(views: [title, RowKit.spacer(), amount])
        row.orientation = .horizontal
        row.spacing = MacTheme.Spacing.s
        block.addArrangedSubview(row)

        if !isBalance {
            block.addArrangedSubview(
                UsageFormat.fullWidthBar(
                    fraction: fraction, height: 6,
                    fill: UsageFormat.fillColor(severity: severity, slug: slug)))
        }

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

    private static func badge(for quota: UsageQuota) -> NSView {
        let text = QuotaSurface.badge(quota)
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Ramp.font(.metricLabel)
        label.textColor = quota.live ? MacTheme.Color.success : MacTheme.Color.secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 4
        wrap.layer?.backgroundColor =
            (quota.live
                ? MacTheme.Color.success.withAlphaComponent(0.15)
                : MacTheme.Color.secondaryLabel.withAlphaComponent(0.15)).cgColor
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
