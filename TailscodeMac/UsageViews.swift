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
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: QuotaBoardStore.didChange, object: nil)
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
        let glance = QuotaGlance.make(
            from: folded, answeredAt: answeredAt, board: QuotaBoardStore.current)
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

/// The full quota picture behind the toolbar gauge, in a window of its own rather than a popover
/// the width of a phone: the board's switches across the top — every provider the account
/// reported or this Mac can offer a key for, shown or hidden with one press, the arrangement and
/// the lead beside them — then the tightest window as one wide bar, then a card per provider two
/// across, each with its windows as bars that fill the card, its reset, its money and the facts
/// the provider reports. Which cards, in what order and whether the lead shows is
/// ``QuotaBoard``'s; this decides only how a card is drawn. Opens on what the footer already
/// knows, then refetches so the numbers are current; the refresh button asks again.
@MainActor
final class UsagePanelViewController: NSViewController {
    private let boardBar = NSStackView()
    private let column = FillingStack()
    private var quotas: [(String, UsageQuota)]
    private let refresh: () async -> [(String, UsageQuota)]
    private let onAnalytics: () -> Void
    private var refreshing = false
    /// The prepaid balance is this Mac's own reading rather than a server's report, so it is held
    /// beside the servers' quotas and folded in only where the cards are built.
    private var balance: DeepSeekBalance.Reading?
    private let arrangementPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let leadSwitch = NSButton(
        checkboxWithTitle: Localized.text("Lead with the tightest"), target: nil, action: nil)

    static let openingSize = NSSize(width: 780, height: 760)

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardChanged), name: QuotaBoardStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        boardBar.orientation = .horizontal
        boardBar.alignment = .centerY
        boardBar.spacing = MacTheme.Spacing.s
        boardBar.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.xs,
            right: MacTheme.Spacing.l)
        boardBar.translatesAutoresizingMaskIntoConstraints = false

        arrangementPicker.addItems(
            withTitles: QuotaBoardPreferences.Arrangement.allCases.map(\.title))
        arrangementPicker.controlSize = .small
        arrangementPicker.target = self
        arrangementPicker.action = #selector(arrangementPicked)
        arrangementPicker.toolTip = Localized.text("How the cards are arranged")
        leadSwitch.controlSize = .small
        leadSwitch.target = self
        leadSwitch.action = #selector(leadToggled)

        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
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
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = FillingStack(views: [boardBar, scroll, footer])
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        renderCards()
        startRefresh()
    }

    func startRefresh() {
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

    @objc private func boardChanged() {
        view.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        renderCards()
    }

    @objc private func arrangementPicked() {
        let index = arrangementPicker.indexOfSelectedItem
        guard QuotaBoardPreferences.Arrangement.allCases.indices.contains(index) else { return }
        let picked = QuotaBoardPreferences.Arrangement.allCases[index]
        guard picked != QuotaBoardStore.current.arrangement else { return }
        QuotaBoardStore.update { $0.arrangement = picked }
    }

    @objc private func leadToggled() {
        let on = leadSwitch.state == .on
        guard on != QuotaBoardStore.current.leadsWithTightest else { return }
        QuotaBoardStore.update { $0.leadsWithTightest = on }
    }

    private func renderCards() {
        let preferences = QuotaBoardStore.current
        let holdings = QuotaRollup.account(from: reports())
        let offers = offers(reported: Set(holdings.map(QuotaBoard.key)))
        renderBoard(
            QuotaBoard.choices(holdings: holdings, offers: offers, preferences: preferences),
            preferences: preferences)

        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let visible = QuotaBoard.arrange(holdings, preferences: preferences)
        let keys = visible.map(QuotaBoard.key)
        if holdings.isEmpty, offers.isEmpty {
            column.addArrangedSubview(
                RowKit.label(
                    refreshing
                        ? Localized.text("Asking the providers…")
                        : Localized.text("No provider reports a quota."),
                    font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.secondaryLabel))
        } else if visible.isEmpty, !holdings.isEmpty {
            column.addArrangedSubview(
                RowKit.label(
                    Localized.text("Every provider is hidden — switch one on above."),
                    font: MacTheme.Ramp.font(.panelLabel), color: MacTheme.Color.secondaryLabel))
        }
        if let lead = QuotaBoard.lead(visible, preferences: preferences) {
            column.addArrangedSubview(heroCard(lead.holding, lead.gauge))
        }
        var cards: [NSView] = visible.enumerated().map { index, holding in
            card(holding, position: index, of: keys)
        }
        for offer in offers where QuotaBoard.shows(offer, preferences: preferences) {
            cards.append(offerCard(offer))
        }
        for pair in stride(from: 0, to: cards.count, by: 2) {
            let row = NSStackView(views: Array(cards[pair..<min(pair + 2, cards.count)]))
            if cards.count - pair == 1 { row.addArrangedSubview(NSView()) }
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = MacTheme.Spacing.m
            row.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(row)
        }
        if refreshing {
            column.addArrangedSubview(
                RowKit.label(
                    Localized.text("Refreshing…"), font: MacTheme.Ramp.font(.panelFootnote),
                    color: MacTheme.Color.tertiaryLabel))
        }
    }

    /// The row of switches: one chip per provider, lit in the brand's colour while it is shown and
    /// dimmed while it is hidden — never removed, because a switch that vanishes when it is off
    /// cannot be switched back — then the arrangement and the lead.
    private func renderBoard(_ choices: [QuotaBoard.Choice], preferences: QuotaBoardPreferences) {
        boardBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for choice in choices {
            let chip = NSButton(title: choice.name, target: self, action: #selector(chipPressed(_:)))
            chip.setButtonType(.pushOnPushOff)
            chip.bezelStyle = .recessed
            chip.controlSize = .small
            chip.state = choice.isHidden ? .off : .on
            chip.identifier = NSUserInterfaceItemIdentifier(choice.key)
            chip.toolTip =
                choice.isHidden
                ? Localized.text("Hidden — press to show %@", choice.name)
                : Localized.text("Shown — press to hide %@", choice.name)
            let slug = ProviderBrand.slug(choice.name) ?? ProviderBrand.brand(choice.name)
            chip.contentTintColor =
                choice.isHidden
                ? MacTheme.Color.tertiaryLabel
                : (UsageFormat.brandColor(slug) ?? MacTheme.Color.label)
            chip.alphaValue = choice.isReported ? 1 : 0.75
            boardBar.addArrangedSubview(chip)
        }
        boardBar.addArrangedSubview(RowKit.spacer())
        arrangementPicker.selectItem(
            at: QuotaBoardPreferences.Arrangement.allCases.firstIndex(of: preferences.arrangement)
                ?? 0)
        leadSwitch.state = preferences.leadsWithTightest ? .on : .off
        boardBar.addArrangedSubview(arrangementPicker)
        boardBar.addArrangedSubview(leadSwitch)
    }

    @objc private func chipPressed(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let hidden = sender.state == .off
        QuotaBoardStore.update { $0.setHidden(key, hidden) }
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

    /// The doors this Mac can only offer a key for. Offered only where it could matter — an
    /// opencode server is what fronts these models — so an account that has never touched them
    /// is not told about them.
    private func offers(reported: Set<String>) -> [QuotaBoard.Offer] {
        let fronted = ServerDirectory.shared.profiles.contains { $0.backend == .openCode }
        var out: [QuotaBoard.Offer] = []
        if !reported.contains("deepseek"), fronted || DeepSeekCredentials.hasToken {
            out.append(QuotaBoard.Offer(key: "deepseek", name: Localized.text("DeepSeek")))
        }
        if !reported.contains("ollama-cloud"), fronted || OllamaCredentials.hasToken {
            out.append(QuotaBoard.Offer(key: "ollama-cloud", name: OllamaCloud.providerName))
        }
        return out
    }

    /// What the panel says about a door with no reading to draw: a key nobody has set is a state
    /// with words and one action rather than a blank space, and a key that has been set but not
    /// yet answered for says exactly that instead of reading as an account with no money.
    private func offerCard(_ offer: QuotaBoard.Offer) -> NSView {
        let deepseek = offer.key == "deepseek"
        let hasKey = deepseek ? DeepSeekCredentials.hasToken : OllamaCredentials.hasToken
        let words: String
        if deepseek {
            words =
                hasKey
                ? Localized.text(
                    "The key is set and api.deepseek.com has not answered yet — the prepaid balance appears here as soon as it does.")
                : Localized.text(
                    "DeepSeek models billed straight to your own platform account are metered by a prepaid balance rather than by a plan. Add the key and the balance joins these numbers.")
        } else {
            words =
                hasKey
                ? Localized.text(
                    "The key is set and ollama.com has not answered yet — the plan's windows appear here as soon as it does.")
                : Localized.text(
                    "Ollama models served by ollama.com are metered by your plan. Add the account's API key and the session and weekly windows join these numbers.")
        }
        let action = hasKey ? Localized.text("Edit key…") : Localized.text("Add key…")

        let card = Self.cardStack()
        card.addArrangedSubview(
            RowKit.label(
                offer.name, font: MacTheme.Ramp.font(.panelTitle),
                color: UsageFormat.brandColor(offer.key) ?? MacTheme.Color.label))
        card.addArrangedSubview(
            RowKit.wrapping(
                words, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel))
        let button = RowKit.ActionButton(title: action) { [weak self] in
            if deepseek { self?.editDeepSeekKey() } else { self?.editOllamaKey() }
        }
        button.controlSize = .small
        let row = NSStackView(views: [button, RowKit.spacer()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = MacTheme.Spacing.s
        card.addArrangedSubview(row)
        return card
    }

    private func editOllamaKey() {
        OllamaKeySheet.present(on: view.window) { [weak self] in
            guard let self else { return }
            self.renderCards()
            self.startRefresh()
        }
    }

    private func editDeepSeekKey() {
        DeepSeekKeySheet.present(on: view.window) { [weak self] in
            guard let self else { return }
            self.balance = DeepSeekBalance.cached
            self.renderCards()
            self.startRefresh()
        }
    }

    private static func cardStack() -> FillingStack {
        let card = FillingStack()
        card.spacing = MacTheme.Spacing.s
        card.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        card.wantsLayer = true
        card.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        card.layer?.cornerRadius = MacTheme.Radius.control
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    /// The board leads with the tightest window across the visible providers — the one that
    /// decides when the next send unlocks — as one big bar with its countdown.
    private func heroCard(_ holding: QuotaHolding, _ gauge: UsageQuota.Gauge) -> NSView {
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

        var views: [NSView] = [caption, nameRow]
        if !UsageFormat.isBalance(gauge) {
            views.append(
                UsageFormat.fullWidthBar(
                    fraction: fraction, height: 9,
                    fill: UsageFormat.fillColor(severity: severity, slug: slug)))
        }
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
        let hero = Self.cardStack()
        hero.layer?.borderWidth = 1
        hero.layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.35).cgColor
        for view in views { hero.addArrangedSubview(view) }
        return hero
    }

    private func card(_ holding: QuotaHolding, position: Int, of keys: [String]) -> NSView {
        let quota = holding.quota
        let slug = holding.slug
        let card = Self.cardStack()

        let name = RowKit.label(
            quota.providerName, font: MacTheme.Ramp.font(.panelTitle),
            color: UsageFormat.brandColor(slug) ?? MacTheme.Color.label)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [name])
        if !quota.subtitle.isEmpty {
            let plan = RowKit.label(
                quota.subtitle, font: MacTheme.Ramp.font(.panelFootnote),
                color: MacTheme.Color.secondaryLabel)
            plan.lineBreakMode = .byTruncatingTail
            plan.setContentCompressionResistancePriority(.init(100), for: .horizontal)
            header.addArrangedSubview(plan)
        }
        header.addArrangedSubview(RowKit.spacer())
        header.addArrangedSubview(Self.badge(for: quota))
        header.addArrangedSubview(moveButtons(for: QuotaBoard.key(holding), position: position, of: keys))
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

    /// A card is moved from its own header, one place at a time; the ends are disabled rather
    /// than absent, so the two arrows sit in the same place on every card.
    private func moveButtons(for key: String, position: Int, of keys: [String]) -> NSView {
        let up = MoveButton(symbol: "chevron.up", tip: Localized.text("Move up")) {
            QuotaBoardStore.update { $0.move(key, by: -1, among: keys) }
        }
        up.isEnabled = position > 0
        let down = MoveButton(symbol: "chevron.down", tip: Localized.text("Move down")) {
            QuotaBoardStore.update { $0.move(key, by: 1, among: keys) }
        }
        down.isEnabled = position < keys.count - 1
        let row = NSStackView(views: [up, down])
        row.orientation = .horizontal
        row.spacing = 0
        return row
    }

    private final class MoveButton: NSButton {
        private let handler: () -> Void

        init(symbol: String, tip: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(frame: .zero)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            imagePosition = .imageOnly
            isBordered = false
            bezelStyle = .accessoryBarAction
            controlSize = .small
            toolTip = tip
            contentTintColor = MacTheme.Color.secondaryLabel
            target = self
            self.action = #selector(pressed)
            setContentHuggingPriority(.required, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func pressed() { handler() }
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

/// The usage board in a titled window of its own, one per app: a popover the width of a phone
/// could hold one column of cards and nothing about the board, and it closed the moment the
/// keyboard moved. Held in a property by whoever presents it, because a window presented from a
/// local is dead on arrival.
@MainActor
final class UsageWindowController: NSWindowController {
    private let panel: UsagePanelViewController

    init(
        initial: [(String, UsageQuota)],
        refresh: @escaping () async -> [(String, UsageQuota)],
        onAnalytics: @escaping () -> Void
    ) {
        panel = UsagePanelViewController(
            initial: initial, refresh: refresh, onAnalytics: onAnalytics)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: UsagePanelViewController.openingSize),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Usage")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 320)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentViewController = panel
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens at the size the board was drawn for, and asks the providers again on every showing.
    func present() {
        if let window, !window.isVisible, let screen = window.screen ?? NSScreen.main {
            let room = screen.visibleFrame
            let size = NSSize(
                width: min(UsagePanelViewController.openingSize.width, room.width - 80),
                height: min(UsagePanelViewController.openingSize.height, room.height - 80))
            window.setFrame(
                NSRect(
                    x: room.midX - size.width / 2, y: room.midY - size.height / 2,
                    width: size.width, height: size.height),
                display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        panel.startRefresh()
    }
}
