import AppKit
import TailscodeCore

/// The Software Updates window: one card per machine in the picture — this app and every server it
/// talks to — each saying what it runs, what it could run, who said so, and the one press that
/// changes it.
///
/// The content is a view controller rather than a bare content view for the same reason the git
/// panel is one: the whole surface can then be built and checked with no window server behind it.
@MainActor
final class UpdateWindowController: NSWindowController {
    private let board = UpdateBoardViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Localized.text("Software Updates")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 320)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentView = Self.holder(for: board.view)
        window.center()
        window.rememberFrame(as: "TailscodeUpdates")
    }

    /// A content view laid out by constraints is one the window fits itself to, and a column of
    /// wrapping labels fits as narrow as its narrowest button — the window opened a hundred and
    /// thirty points wide. Held in a plain view, the board fills whatever size the window is.
    private static func holder(for board: NSView) -> NSView {
        let holder = NSView()
        board.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(board)
        NSLayoutConstraint.activate([
            board.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            board.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            board.topAnchor.constraint(equalTo: holder.topAnchor),
            board.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        board.open()
    }
}

/// Every machine's answer, drawn from what this device already knew.
///
/// It renders from `UpdateLedger` the instant it opens — a surface that waited for the network
/// would be blank exactly when the network is worst — and opening only asks if a check is actually
/// due; the driver's own loop and the hero's "Check now" are what force one. Cards are opaque
/// canvas: an update is content, and prose never sits on glass.
///
/// Nothing is rebuilt on a ledger post. A job in flight lands a new reading every couple of seconds
/// for minutes on end, so the column is rebuilt only when the *set or order* of machines changes —
/// the cards themselves, which outlive that, simply rewrite their own labels. A board that rebuilt
/// itself on every answer would throw away the scroll position and whatever button was under the
/// pointer, on the one screen where somebody is watching a button.
@MainActor
final class UpdateBoardViewController: NSViewController {
    private let column = FillingStack()
    private let scroll = AppearanceReportingScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let heroHeadline = NSTextField(labelWithString: "")
    private let heroDetail = NSTextField(wrappingLabelWithString: "")
    private let heroChecked = NSTextField(labelWithString: "")
    private let heroCard = FillingStack()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var updateAllButton = RowKit.ActionButton(
        title: "", action: { [weak self] in self?.updateEverything() })
    private lazy var checkNowButton = RowKit.ActionButton(
        title: Localized.text("Check now"), action: { [weak self] in self?.checkNow() })
    private var cards: [String: UpdateCardView] = [:]
    /// The machines the column is currently laid out for, in the order Core ranked them. A rank
    /// that changes is a real change of content and earns a relayout; the same list in the same
    /// order never does.
    private var order: [String] = []

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.onAppearanceChange = { [weak self] in self?.applyTheme() }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        view = scroll

        buildHero()

        emptyLabel.stringValue = Localized.text(
            "Nothing has been asked yet. This app and every server you add answer for their own "
                + "software.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: MacUpdateWatch.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        applyTheme()
        render()
    }

    /// Opening the window is asking whether a check is actually due — the driver's own loop keeps
    /// every card current in the background, so looking at this window twice in a minute costs
    /// nothing. The cards are already up from memory the moment it draws.
    func open() {
        applyTheme()
        render()
        MacUpdateWatch.shared.checkIfDue()
    }

    @objc private func changed() {
        render()
    }

    @objc private func repaint() {
        applyTheme()
        render()
    }

    private func render() {
        let rollup = UpdateLedger.rollup()
        let snapshot = MacUpdateWatch.shared.snapshot
        let ids = rollup.readings.map(\.id)
        if ids != order || column.arrangedSubviews.isEmpty { relayout(rollup, ids: ids) }
        writeHero(rollup, snapshot: snapshot)
        for reading in rollup.readings {
            cards[reading.id]?.apply(
                UpdateCard(
                    reading, acknowledged: rollup.isAcknowledged(reading),
                    busy: snapshot.isBusy(reading.component)))
        }
    }

    /// The column rebuilt around a new set — or a new order — of machines. The cards themselves
    /// are kept and re-arranged rather than made again, so a machine that merely moved up the list
    /// carries its own clock and its own open sections with it.
    private func relayout(_ rollup: UpdateRollup, ids: [String]) {
        for stale in Set(cards.keys).subtracting(ids) { cards.removeValue(forKey: stale) }
        for arranged in column.arrangedSubviews { arranged.removeFromSuperview() }
        column.addArrangedSubview(heroCard)
        for id in ids {
            let card = cards[id] ?? makeCard(id)
            cards[id] = card
            column.addArrangedSubview(card)
        }
        emptyLabel.isHidden = !rollup.readings.isEmpty
        column.addArrangedSubview(emptyLabel)
        order = ids
    }

    private func makeCard(_ id: String) -> UpdateCardView {
        let card = UpdateCardView(style: .standalone)
        card.onAction = { [weak self] action in
            guard let self, let reading = self.reading(id) else { return }
            UpdatePress.perform(action, for: reading, from: self.view.window) { [weak self] text in
                self?.setStatus(text)
            }
        }
        card.onAutomation = { [weak self, weak card] enabled in
            guard let self, let card, let reading = self.reading(id) else { return }
            UpdatePress.setAutomation(enabled, for: reading, card: card)
        }
        return card
    }

    private func reading(_ id: String) -> UpdateReading? {
        UpdateLedger.rollup().readings.first { $0.id == id }
    }

    /// What every machine adds up to, in the words Core gives the mark itself — so the line at the
    /// top of this window and the line in the sidebar are the same sentence. The status line lives
    /// here too, under the machine controls, rather than pinned outside the scroll: a second view
    /// standing beside the scroll view as a sibling is exactly the shape that stopped answering to
    /// the window's own size.
    private func buildHero() {
        heroHeadline.translatesAutoresizingMaskIntoConstraints = false
        heroDetail.translatesAutoresizingMaskIntoConstraints = false
        heroDetail.isSelectable = true
        heroDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heroChecked.translatesAutoresizingMaskIntoConstraints = false
        updateAllButton.bezelStyle = .rounded
        updateAllButton.keyEquivalent = ""
        updateAllButton.bezelColor = MacTheme.Color.accent
        checkNowButton.bezelStyle = .rounded
        checkNowButton.keyEquivalent = ""
        let buttons = NSStackView(views: [updateAllButton, checkNowButton, RowKit.spacer()])
        buttons.orientation = .horizontal
        buttons.spacing = MacTheme.Spacing.s
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        heroCard.spacing = MacTheme.Spacing.s
        heroCard.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        heroCard.wantsLayer = true
        heroCard.layer?.cornerRadius = MacTheme.Radius.card
        heroCard.layer?.borderWidth = 1
        heroCard.translatesAutoresizingMaskIntoConstraints = false
        for row in [heroHeadline, heroDetail, buttons, heroChecked, statusLabel] {
            heroCard.addArrangedSubview(row)
        }
    }

    private func writeHero(_ rollup: UpdateRollup, snapshot: UpdateDriver.Snapshot) {
        heroHeadline.stringValue = rollup.headline
        heroDetail.stringValue = rollup.detail()
        heroDetail.isHidden = heroDetail.stringValue.isEmpty
        if let walk = snapshot.walk {
            updateAllButton.isHidden = false
            updateAllButton.isEnabled = false
            updateAllButton.title = Localized.text(
                "Updating %@ of %@…", String(min(walk.done + 1, walk.total)), String(walk.total))
        } else {
            updateAllButton.isHidden = !rollup.canUpdateEverything
            updateAllButton.isEnabled = true
            updateAllButton.title = Localized.text(
                "Update all %@ servers", String(rollup.installableServers.count))
        }
        checkNowButton.isEnabled = !snapshot.checking
        if snapshot.checking {
            heroChecked.stringValue = Localized.text("Checking every machine…")
        } else if let last = UpdateLedger.lastCheck() {
            heroChecked.stringValue = Localized.text("Last checked %@", RelativeWhen.ago(last))
        } else {
            heroChecked.stringValue = ""
        }
        heroChecked.isHidden = heroChecked.stringValue.isEmpty
    }

    private func updateEverything() {
        let count = UpdateLedger.rollup().installableServers.count
        MacDialogs.confirm(
            on: view.window, title: Localized.text("Update all %@ servers?", String(count)),
            body: Localized.text(
                "One at a time: each downloads and builds, then restarts once nothing is running "
                    + "on it."),
            confirmLabel: Localized.text("Update all"), destructive: false
        ) {
            Task { await MacUpdateWatch.shared.updateEverything() }
        }
    }

    private func checkNow() {
        Task { await MacUpdateWatch.shared.checkAll() }
    }

    /// The tokens are values rather than dynamic colours and the fonts carry the type scale, so a
    /// repaint has to walk every label that is already on screen — including the cards', which
    /// outlive the change that caused it.
    private func applyTheme() {
        scroll.backgroundColor = MacTheme.Color.canvas
        heroCard.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        heroCard.layer?.borderColor = MacTheme.Color.separator.cgColor
        heroHeadline.font = MacTheme.Ramp.font(.headline)
        heroHeadline.textColor = MacTheme.Color.label
        heroDetail.font = MacTheme.Ramp.font(.panelFootnote)
        heroDetail.textColor = MacTheme.Color.secondaryLabel
        heroChecked.font = MacTheme.Ramp.font(.panelFootnote)
        heroChecked.textColor = MacTheme.Color.tertiaryLabel
        updateAllButton.font = MacTheme.Ramp.font(.control)
        checkNowButton.font = MacTheme.Ramp.font(.control)
        emptyLabel.font = MacTheme.Ramp.font(.panelLabel)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        statusLabel.font = MacTheme.Ramp.font(.panelFootnote)
        statusLabel.textColor = MacTheme.Color.secondaryLabel
        for card in cards.values { card.applyTheme() }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }
}

/// The one thing on this screen that can hear a light↔dark switch, on the scroll view standing in
/// as the window's own content view.
///
/// `NSViewController` has no appearance hook at all, and the hero card's ground and hairline are
/// baked `CGColor`s: nothing else would ask for them again, so the leading card would keep the
/// light ground it was born with under white ink until the theme happened to change.
@MainActor
final class AppearanceReportingScrollView: NSScrollView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
