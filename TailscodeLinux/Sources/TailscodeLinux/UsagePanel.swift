import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The full quota picture behind the sidebar footer, laid out for a desk rather than a phone:
/// the board's switches across the top — every provider the account reported or this client can
/// offer, shown or hidden with one press, the arrangement and the lead beside them — then the
/// tightest window as one wide bar, then a card per provider two across, each with its windows
/// as bars that fill the card, its reset, its money and the facts the provider reports. Which
/// cards, in what order and whether the lead shows is ``QuotaBoard``'s; this file draws it.
/// Opens on what the footer already knows, then refetches so the numbers are current, and hands
/// over to ``AnalyticsPanel`` for the whole month.
final class UsagePanel: @unchecked Sendable {
    static let trackWidth = 320
    private static let heroTrackWidth = 704
    private static let windowWidth: Int32 = 780
    private static let windowHeight: Int32 = 760

    /// The open panel. A class-backed window presented from a local is dead on arrival — released
    /// while shown, its buttons do nothing — so the panel holds itself here until its window goes.
    private nonisolated(unsafe) static var open: UsagePanel?

    private var quotas: [(String, UsageQuota)]
    private let refresh: @Sendable () async -> [(String, UsageQuota)]
    private var refreshing = false
    /// Whether an opencode server is connected — the one place the metered doors could matter.
    private var fronted: Bool
    private let windowBits: UInt
    private let boardBits: UInt
    private let columnBits: UInt

    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        initial: [(String, UsageQuota)],
        refresh: @escaping @Sendable () async -> [(String, UsageQuota)]
    ) async {
        if let open, let raw = UnsafeMutableRawPointer(bitPattern: open.windowBits) {
            gtk_window_present(ptr(raw))
            return
        }
        let fronted = await ServerDirectory.shared.profiles().contains { $0.backend == .openCode }
        let parentBits = UInt(bitPattern: parent)
        Gtk.onMain {
            let panel = UsagePanel(
                parent: UnsafeMutableRawPointer(bitPattern: parentBits).map { ptr($0) },
                initial: initial, fronted: fronted, refresh: refresh)
            open = panel
            panel.render()
            panel.startRefresh()
        }
    }

    private init(
        parent: UnsafeMutablePointer<GtkWidget>?, initial: [(String, UsageQuota)], fronted: Bool,
        refresh: @escaping @Sendable () async -> [(String, UsageQuota)]
    ) {
        self.quotas = initial
        self.refresh = refresh
        self.fronted = fronted
        let (window, content) = Dialogs.window(
            title: Localized.text("Usage"), parent: parent, width: Self.windowWidth)
        gtk_window_set_default_size(ptr(window), Self.windowWidth, Self.windowHeight)
        windowBits = UInt(bitPattern: window)

        let board = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        Gtk.addClass(board, "usage-board")
        gtk_box_append(ptr(content), board)
        boardBits = UInt(bitPattern: board)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        columnBits = UInt(bitPattern: column)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_box_append(ptr(content), scroller)

        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let contentBits = UInt(bitPattern: content)
        let month = Gtk.button(Localized.text("The month in numbers"), css: ["analytics-open"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: contentBits) else { return }
            AnalyticsPanel.present(parent: ptr(raw))
        }
        gtk_widget_set_hexpand(month, 1)
        gtk_box_append(ptr(actions), month)
        let again = Gtk.button(Localized.text("Refresh")) { [weak self] in
            Gtk.onMain { [weak self] in self?.startRefresh() }
        }
        gtk_box_append(ptr(actions), again)
        let closing = windowBits
        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: closing) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), dismiss)
        gtk_box_append(ptr(content), actions)

        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") {
            Gtk.onMain { UsagePanel.open = nil }
        }
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)
    }

    private func startRefresh() {
        guard !refreshing else { return }
        refreshing = true
        render()
        let refresh = self.refresh
        Task.detached { [weak self] in
            let fresh = await refresh()
            let fronted = await ServerDirectory.shared.profiles().contains {
                $0.backend == .openCode
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if !fresh.isEmpty { self.quotas = fresh }
                self.fronted = fronted
                self.refreshing = false
                self.render()
            }
        }
    }

    private var column: UnsafeMutablePointer<GtkWidget>? {
        UnsafeMutableRawPointer(bitPattern: columnBits).map { ptr($0) }
    }

    private var board: UnsafeMutablePointer<GtkWidget>? {
        UnsafeMutableRawPointer(bitPattern: boardBits).map { ptr($0) }
    }

    private var window: UnsafeMutablePointer<GtkWidget>? {
        UnsafeMutableRawPointer(bitPattern: windowBits).map { ptr($0) }
    }

    private func change(_ edit: (inout QuotaBoardPreferences) -> Void) {
        QuotaBoardStore.update(edit)
        render()
    }

    /// Everything the board could show: what the account reported, plus the doors this client
    /// can only offer a key for. An offer is shown only where it could matter — an opencode server
    /// fronts these models — so an account that never touched them is not told about them.
    private func offers() -> [QuotaBoard.Offer] {
        var out: [QuotaBoard.Offer] = []
        let holdings = QuotaRollup.account(from: quotas)
        let reported = Set(holdings.map(QuotaBoard.key))
        if !reported.contains("deepseek"), fronted || DeepSeekCredentials.hasToken {
            out.append(QuotaBoard.Offer(key: "deepseek", name: "DeepSeek"))
        }
        if !reported.contains("ollama-cloud"), fronted || OllamaCredentials.hasToken {
            out.append(QuotaBoard.Offer(key: "ollama-cloud", name: OllamaCloud.providerName))
        }
        return out
    }

    private func render() {
        guard let column, let board else { return }
        let preferences = QuotaBoardStore.current
        let holdings = QuotaRollup.account(from: quotas)
        let offers = offers()
        renderBoard(
            into: board,
            choices: QuotaBoard.choices(
                holdings: holdings, offers: offers, preferences: preferences),
            preferences: preferences)

        Gtk.removeChildren(of: column)
        let visible = QuotaBoard.arrange(holdings, preferences: preferences)
        let keys = visible.map(QuotaBoard.key)
        if holdings.isEmpty, offers.isEmpty {
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    refreshing
                        ? Localized.text("Asking the providers…")
                        : Localized.text("No provider reports a quota."),
                    css: "dim", selectable: false))
        } else if visible.isEmpty, !holdings.isEmpty {
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    Localized.text("Every provider is hidden — switch one on above."),
                    css: "dim", selectable: false))
        }
        if let lead = QuotaBoard.lead(visible, preferences: preferences) {
            gtk_box_append(ptr(column), hero(quota: lead.holding.quota, gauge: lead.gauge))
        }
        var cards: [UnsafeMutablePointer<GtkWidget>] = visible.enumerated().map { index, holding in
            card(holding, position: index, of: keys)
        }
        for offer in offers where QuotaBoard.shows(offer, preferences: preferences) {
            if let invitation = offerCard(offer) { cards.append(invitation) }
        }
        if !cards.isEmpty {
            let grid = gtk_grid_new()!
            gtk_grid_set_column_homogeneous(ptr(grid), 1)
            gtk_grid_set_column_spacing(ptr(grid), 12)
            gtk_grid_set_row_spacing(ptr(grid), 12)
            for (index, card) in cards.enumerated() {
                gtk_widget_set_hexpand(card, 1)
                gtk_widget_set_valign(card, GTK_ALIGN_START)
                gtk_grid_attach(ptr(grid), card, Int32(index % 2), Int32(index / 2), 1, 1)
            }
            gtk_box_append(ptr(column), grid)
        }
        if refreshing {
            gtk_box_append(
                ptr(column), Gtk.label(Localized.text("Refreshing…"), css: "dim", selectable: false))
        }
    }

    /// The row of switches: one chip per provider, lit in the brand's colour while it is shown and
    /// dimmed while it is hidden — never removed, because a switch that vanishes when it is off
    /// cannot be switched back — then the arrangement and the lead.
    private func renderBoard(
        into board: UnsafeMutablePointer<GtkWidget>, choices: [QuotaBoard.Choice],
        preferences: QuotaBoardPreferences
    ) {
        Gtk.removeChildren(of: board)
        let chips = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_hexpand(chips, 1)
        for choice in choices {
            let chip = gtk_toggle_button_new_with_label(choice.name)!
            Gtk.addClass(chip, "usage-chip")
            if let slug = ProviderBrand.slug(choice.name) ?? ProviderBrand.brand(choice.name) {
                Gtk.addClass(chip, "chip-\(slug)")
            }
            if !choice.isReported { Gtk.addClass(chip, "usage-chip-offer") }
            gtk_toggle_button_set_active(ptr(chip), choice.isHidden ? 0 : 1)
            gtk_widget_set_tooltip_text(
                chip,
                choice.isHidden
                    ? Localized.text("Hidden — press to show %@", choice.name)
                    : Localized.text("Shown — press to hide %@", choice.name))
            let key = choice.key
            let chipBits = UInt(bitPattern: chip)
            Gtk.connect(UnsafeMutableRawPointer(chip), "toggled") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let raw = UnsafeMutableRawPointer(bitPattern: chipBits) else { return }
                    let shown = gtk_toggle_button_get_active(ptr(raw)) != 0
                    self?.change { $0.setHidden(key, !shown) }
                }
            }
            gtk_box_append(ptr(chips), chip)
        }
        gtk_box_append(ptr(board), chips)

        let arrangement = Gtk.menuButton(
            preferences.arrangement.title, css: ["usage-arrangement"],
            rows: { [weak self] in
                QuotaBoardPreferences.Arrangement.allCases.map { option in
                    (
                        title: option.title, detail: nil,
                        action: { [weak self] in
                            Gtk.onMain { [weak self] in
                                self?.change { $0.arrangement = option }
                            }
                        }
                    )
                }
            })
        gtk_widget_set_tooltip_text(arrangement, Localized.text("How the cards are arranged"))
        gtk_box_append(ptr(board), arrangement)

        let lead = gtk_check_button_new_with_label(Localized.text("Lead with the tightest"))!
        Gtk.addClass(lead, "usage-lead")
        gtk_check_button_set_active(ptr(lead), preferences.leadsWithTightest ? 1 : 0)
        let leadBits = UInt(bitPattern: lead)
        Gtk.connect(UnsafeMutableRawPointer(lead), "toggled") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let raw = UnsafeMutableRawPointer(bitPattern: leadBits) else { return }
                let on = gtk_check_button_get_active(ptr(raw)) != 0
                guard on != QuotaBoardStore.current.leadsWithTightest else { return }
                self?.change { $0.leadsWithTightest = on }
            }
        }
        gtk_box_append(ptr(board), lead)
    }

    /// What the panel says about a door with no reading to draw: a key nobody has set is a state
    /// with words and one action rather than a blank space, and a key that has been set but not
    /// answered for says exactly that.
    private func offerCard(_ offer: QuotaBoard.Offer) -> UnsafeMutablePointer<GtkWidget>? {
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
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(offer.name, css: "usage-provider", selectable: false)
        Gtk.addClass(name, "brand-\(offer.key)")
        gtk_box_append(ptr(header), name)
        gtk_box_append(ptr(header), Gtk.label("", css: "usage-plan", selectable: false))
        gtk_box_append(ptr(card), header)
        gtk_box_append(ptr(card), Gtk.label(words, css: "row-detail", wrap: true, selectable: false))
        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        let title = hasKey ? Localized.text("Edit key…") : Localized.text("Add key…")
        let parentBits = windowBits
        gtk_box_append(
            ptr(buttons),
            Gtk.button(title, css: ["suggested-action"]) { [weak self] in
                Gtk.onMain { [weak self] in
                    let parent: UnsafeMutablePointer<GtkWidget>? =
                        UnsafeMutableRawPointer(bitPattern: parentBits).map { ptr($0) }
                    let changed: @Sendable () -> Void = { [weak self] in
                        Gtk.onMain { [weak self] in self?.startRefresh() }
                    }
                    if deepseek {
                        DeepSeekKeyDialog.present(parent: parent, onChanged: changed)
                    } else {
                        OllamaKeyDialog.present(parent: parent, onChanged: changed)
                    }
                }
            })
        gtk_box_append(ptr(card), buttons)
        return card
    }

    private func hero(quota: UsageQuota, gauge: UsageQuota.Gauge)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(card, "usage-card")
        Gtk.addClass(card, "usage-hero")
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = fraction > 0.85 ? "danger" : fraction >= 0.6 ? "warn" : "ok"
        let slug = ProviderBrand.slug(quota.providerName)

        gtk_box_append(
            ptr(card),
            Gtk.label(Localized.text("Tightest window"), css: "usage-source", selectable: false))
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(quota.providerName, css: "usage-provider", selectable: false)
        if let slug { Gtk.addClass(name, "brand-\(slug)") }
        gtk_box_append(ptr(header), name)
        gtk_box_append(ptr(header), Gtk.label(gauge.label, css: "usage-plan", selectable: false))
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(header), spacer)
        let percent = Gtk.label(
            Self.amount(for: gauge), css: "analytics-hero-percent", selectable: false)
        Gtk.addClass(percent, "hero-\(severity)")
        gtk_label_set_ellipsize(op(percent), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(header), percent)
        gtk_box_append(ptr(card), header)

        if !QuotaBoard.isBalance(gauge) {
            let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(track, "gauge-track")
            gtk_widget_set_size_request(track, Int32(Self.heroTrackWidth), 10)
            gtk_widget_set_hexpand(track, 1)
            let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(fill, ProviderBrand.fillClass(severity: severity, slug: slug))
            gtk_widget_set_size_request(
                fill, Int32((fraction * Double(Self.heroTrackWidth)).rounded()), 10)
            gtk_widget_set_halign(fill, GTK_ALIGN_START)
            gtk_box_append(ptr(track), fill)
            gtk_box_append(ptr(card), track)
        }

        if let resets = gauge.resetsAt {
            let phrasing =
                gauge.trustedReset
                ? Localized.text("resets in %@", Self.countdown(to: resets))
                : Localized.text("resets in about %@", Self.countdown(to: resets))
            gtk_box_append(ptr(card), Gtk.label(phrasing, css: "gauge-reset", selectable: false))
        }
        return card
    }

    private func card(_ holding: QuotaHolding, position: Int, of keys: [String])
        -> UnsafeMutablePointer<GtkWidget>
    {
        let quota = holding.quota
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
        Gtk.addClass(card, "usage-card")

        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let name = Gtk.label(quota.providerName, css: "usage-provider", selectable: false)
        if let slug = ProviderBrand.slug(quota.providerName) {
            Gtk.addClass(name, "brand-\(slug)")
        }
        gtk_box_append(ptr(header), name)
        if !quota.subtitle.isEmpty {
            let plan = Gtk.label(quota.subtitle, css: "usage-plan", selectable: false)
            gtk_label_set_ellipsize(op(plan), PANGO_ELLIPSIZE_END)
            gtk_box_append(ptr(header), plan)
        }
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(header), spacer)
        let badgeText = QuotaSurface.badge(quota)
        let badge = Gtk.label(
            badgeText,
            css: badgeText == Localized.text("LIVE") ? "usage-live" : "usage-stale",
            selectable: false)
        gtk_label_set_ellipsize(op(badge), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(header), badge)
        gtk_box_append(ptr(header), moveButtons(for: QuotaBoard.key(holding), position: position, of: keys))
        gtk_box_append(ptr(card), header)

        let slug = ProviderBrand.slug(quota.providerName)
        for gauge in quota.gauges {
            gtk_box_append(ptr(card), Self.gaugeRows(gauge, slug: slug, quota: quota))
        }

        gtk_box_append(
            ptr(card),
            Gtk.label(QuotaRollup.provenance(holding), css: "usage-source", selectable: false))

        if !quota.details.isEmpty {
            let header = Gtk.label(
                Localized.text("How this is counted"), css: "usage-source", selectable: false)
            let disclosure = Gtk.disclosure(
                header: header, expanded: false,
                onToggle: { _, _ in },
                makeBody: {
                    let body = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
                    for detail in quota.details {
                        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
                        let key = Gtk.label(detail.key, css: "usage-detail-key", selectable: false)
                        gtk_widget_set_hexpand(key, 1)
                        gtk_label_set_xalign(op(key), 0)
                        gtk_box_append(ptr(row), key)
                        gtk_box_append(
                            ptr(row),
                            Gtk.label(detail.value, css: "usage-detail-value", selectable: false))
                        gtk_box_append(ptr(body), row)
                    }
                    return body
                })
            gtk_box_append(ptr(card), disclosure)
        }
        return card
    }

    /// A card is moved from its own header, one place at a time; the ends are disabled rather
    /// than absent, so the two arrows sit in the same place on every card.
    private func moveButtons(for key: String, position: Int, of keys: [String])
        -> UnsafeMutablePointer<GtkWidget>
    {
        let box = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        let up = Gtk.button("▲", css: ["usage-move"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.change { $0.move(key, by: -1, among: keys) } }
        }
        gtk_widget_set_tooltip_text(up, Localized.text("Move up"))
        gtk_widget_set_sensitive(up, position > 0 ? 1 : 0)
        let down = Gtk.button("▼", css: ["usage-move"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.change { $0.move(key, by: 1, among: keys) } }
        }
        gtk_widget_set_tooltip_text(down, Localized.text("Move down"))
        gtk_widget_set_sensitive(down, position < keys.count - 1 ? 1 : 0)
        gtk_box_append(ptr(box), up)
        gtk_box_append(ptr(box), down)
        return box
    }

    private static func gaugeRows(
        _ gauge: UsageQuota.Gauge, slug: String?, quota: UsageQuota
    ) -> UnsafeMutablePointer<GtkWidget> {
        let block = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 3)
        let fraction = min(max(gauge.fraction, 0), 1)
        let severity = fraction > 0.85 ? "danger" : fraction >= 0.6 ? "warn" : "ok"
        let isBalance = QuotaBoard.isBalance(gauge)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(gauge.label, css: "usage-gauge-label", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_label_set_xalign(op(title), 0)
        gtk_label_set_ellipsize(op(title), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(row), title)
        let amountLabel = Gtk.label(amount(for: gauge), css: "gauge-\(severity)", selectable: false)
        gtk_label_set_ellipsize(op(amountLabel), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(row), amountLabel)
        gtk_box_append(ptr(block), row)

        if !isBalance {
            let track = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(track, "gauge-track")
            gtk_widget_set_size_request(track, Int32(trackWidth), 6)
            gtk_widget_set_hexpand(track, 1)
            let fill = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            Gtk.addClass(fill, ProviderBrand.fillClass(severity: severity, slug: slug))
            gtk_widget_set_size_request(fill, Int32((fraction * Double(trackWidth)).rounded()), 6)
            gtk_widget_set_halign(fill, GTK_ALIGN_START)
            gtk_box_append(ptr(track), fill)
            gtk_box_append(ptr(block), track)
        }

        gtk_box_append(
            ptr(block),
            Gtk.label(caption(for: gauge, in: quota), css: "gauge-reset", selectable: false))
        return block
    }

    /// One line under the bar: the money where the window is money, and the reset where the
    /// provider said when it comes — never two stacked lines of fine print. A prepaid balance's
    /// caption is its own split, from the snapshot that wrote the card.
    private static func caption(for gauge: UsageQuota.Gauge, in quota: UsageQuota) -> String {
        if QuotaBoard.isBalance(gauge), quota.details.count == 2 {
            return "\(quota.details[0].key) \(quota.details[0].value) · \(quota.details[1].key) \(quota.details[1].value)"
        }
        var parts: [String] = []
        if let used = gauge.usedUSD, let limit = gauge.limitUSD {
            parts.append(
                "\(DeepSeekBalance.money(used, gauge.currency)) / \(DeepSeekBalance.money(limit, gauge.currency))")
        }
        if let resets = gauge.resetsAt {
            let phrasing =
                gauge.trustedReset
                ? Localized.text("resets in %@", countdown(to: resets))
                : Localized.text("resets in about %@", countdown(to: resets))
            parts.append(phrasing)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// A gauge reads as the percent already used — or "Used up" when the window is at the wall.
    /// A prepaid balance is money without a ceiling: the total itself, or "Empty" when the
    /// account is at the wall.
    private static func amount(for gauge: UsageQuota.Gauge) -> String {
        if QuotaBoard.isBalance(gauge) {
            return DeepSeekBalance.amount(for: gauge)
        }
        let percent = "\(Int((min(max(gauge.fraction, 0), 1) * 100).rounded()))%"
        return QuotaSurface.amountLabel(fraction: gauge.fraction, percentText: percent)
    }

    private static func countdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return Localized.text("moments") }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
