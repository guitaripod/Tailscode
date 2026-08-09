import AppKit
import TailscodeCore

/// The Update Center in its own titled window: one card per machine in the picture — this app and
/// every server it talks to — each saying what it runs, what it could run, who said so, and the
/// one press that changes it.
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
        window.title = Localized.text("Software")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 320)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentViewController = board
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        board.reload()
    }
}

/// Every machine's answer, drawn from what this device already knew.
///
/// It renders from `UpdateLedger` the instant it opens — a surface that waited for the network
/// would be blank exactly when the network is worst — and the check it starts behind that corrects
/// the cards in place. Cards are opaque canvas: an update is content, and prose never sits on
/// glass.
///
/// Nothing is rebuilt on a ledger post. An install writes a new reading every three seconds for
/// minutes on end, so the column is rebuilt only when the *order* of machines changes and the
/// cards themselves — which outlive that — simply rewrite their own labels. A board that rebuilt
/// itself on every answer would throw away the scroll position and whatever button was under the
/// pointer, on the one screen where somebody is watching a button.
@MainActor
final class UpdateBoardViewController: NSViewController {
    private let column = NSStackView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let heroHeadline = NSTextField(labelWithString: "")
    private let heroDetail = NSTextField(wrappingLabelWithString: "")
    private let heroChecked = NSTextField(labelWithString: "")
    private let heroCard = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let footerRow = NSStackView()
    private lazy var everythingButton = UpdateReadingViews.button(
        Localized.text("Update everything")
    ) { [weak self] in
        self?.updateEverything()
    }
    private lazy var refreshButton = UpdateReadingViews.button(Localized.text("Refresh")) {
        [weak self] in
        self?.reload()
    }
    private var cards: [String: UpdateCardView] = [:]
    /// The machines the column is currently laid out for, in the order Core ranked them. A rank
    /// that changes is a real change of content and earns a relayout; the same list in the same
    /// order never does.
    private var order: [String] = []
    private var refreshing = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        column.orientation = .vertical
        column.alignment = .width
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

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            column.topAnchor.constraint(equalTo: clip.topAnchor),
            column.widthAnchor.constraint(equalTo: clip.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        buildHero()
        buildFooter()
        emptyLabel.stringValue = Localized.text(
            "Nothing has been asked yet. This app and every server you add answer for their own "
                + "software.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        NotificationCenter.default.addObserver(
            self, selector: #selector(ledgerChanged), name: UpdateLedger.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        applyTheme()
        render()
    }

    /// Opening is asking. The cards are already up from memory, so the check behind them costs
    /// nothing to watch and every answer lands in place as it arrives.
    func reload() {
        guard !refreshing else {
            render()
            return
        }
        refreshing = true
        setStatus(Localized.text("Asking every machine…"))
        render()
        Task { [weak self] in
            await MacUpdateWatch.shared.sweep(checkingRemote: true)
            guard let self else { return }
            self.refreshing = false
            self.render()
        }
    }

    @objc private func ledgerChanged() {
        render()
    }

    @objc private func repaint() {
        applyTheme()
        render()
    }

    private func render() {
        let rollup = UpdateLedger.rollup()
        let ids = rollup.readings.map(\.id)
        if ids != order || column.arrangedSubviews.isEmpty { relayout(rollup, ids: ids) }
        writeHero(rollup)
        for reading in rollup.readings {
            cards[reading.id]?.write(
                reading, acknowledged: rollup.isAcknowledged(reading),
                busy: reading.verdict.isBusy
                    || MacUpdateWatch.shared.isInstalling(reading.component))
        }
        writeFooter(rollup)
    }

    /// The column rebuilt around a new set — or a new order — of machines. The cards themselves
    /// are kept and re-arranged rather than made again, so a machine that merely moved up the list
    /// carries its own clock and its own state with it.
    private func relayout(_ rollup: UpdateRollup, ids: [String]) {
        for stale in Set(cards.keys).subtracting(ids) { cards.removeValue(forKey: stale) }
        for arranged in column.arrangedSubviews { arranged.removeFromSuperview() }
        column.addArrangedSubview(heroCard)
        for reading in rollup.readings {
            let card = cards[reading.id] ?? makeCard()
            cards[reading.id] = card
            column.addArrangedSubview(card)
        }
        emptyLabel.isHidden = !rollup.readings.isEmpty
        column.addArrangedSubview(emptyLabel)
        column.addArrangedSubview(footerRow)
        order = ids
    }

    private func makeCard() -> UpdateCardView {
        let card = UpdateCardView()
        card.onAct = { [weak self] invitation, reading in
            self?.setStatus(UpdateReadingViews.perform(invitation, on: reading))
        }
        card.onSetAside = { reading in UpdateLedger.acknowledge(reading) }
        return card
    }

    /// What every machine adds up to, in the words Core gives the mark itself — so the line at the
    /// top of this window and the line in the sidebar are the same sentence.
    private func buildHero() {
        heroHeadline.translatesAutoresizingMaskIntoConstraints = false
        heroDetail.translatesAutoresizingMaskIntoConstraints = false
        heroDetail.isSelectable = true
        heroDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heroChecked.translatesAutoresizingMaskIntoConstraints = false
        heroCard.orientation = .vertical
        heroCard.alignment = .width
        heroCard.spacing = MacTheme.Spacing.s
        heroCard.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.m, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.m)
        heroCard.wantsLayer = true
        heroCard.layer?.cornerRadius = MacTheme.Radius.card
        heroCard.layer?.borderWidth = 1
        heroCard.translatesAutoresizingMaskIntoConstraints = false
        for row in [heroHeadline, heroDetail, heroChecked] { heroCard.addArrangedSubview(row) }
    }

    private func writeHero(_ rollup: UpdateRollup) {
        heroHeadline.stringValue = rollup.headline
        heroDetail.stringValue = rollup.detail()
        guard let last = UpdateLedger.lastCheck() else {
            heroChecked.isHidden = true
            return
        }
        heroChecked.isHidden = false
        heroChecked.stringValue = Localized.text("Last checked %@", RelativeWhen.ago(last))
    }

    /// One press for every server that can take one — never this app, whose own update would
    /// replace the process doing the watching — and the refresh that asks everybody again.
    private func buildFooter() {
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = MacTheme.Spacing.s
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusLabel, RowKit.spacer(), everythingButton, refreshButton] {
            footerRow.addArrangedSubview(view)
        }
    }

    private func writeFooter(_ rollup: UpdateRollup) {
        everythingButton.isHidden = !rollup.canUpdateEverything
        everythingButton.isEnabled = !refreshing
        refreshButton.isEnabled = !refreshing
    }

    private func updateEverything() {
        let walk = UpdateLedger.rollup().updateOrder
        setStatus(Localized.text("Updating %@ machines, one at a time…", String(walk.count)))
        Task { await MacUpdateWatch.shared.installEverything() }
    }

    /// The tokens are values rather than dynamic colours and the fonts carry the type scale, so a
    /// repaint has to walk every label that is already on screen — including the cards', which
    /// outlive the change that caused it.
    private func applyTheme() {
        scroll.backgroundColor = MacTheme.Color.canvas
        heroCard.layer?.backgroundColor = MacTheme.Color.canvasRaised.cgColor
        heroCard.layer?.borderColor = MacTheme.Color.separator.cgColor
        heroHeadline.font = .systemFont(ofSize: 17 * MacTheme.UIScale.factor, weight: .bold)
        heroHeadline.textColor = MacTheme.Color.label
        heroDetail.font = MacTheme.Font.caption()
        heroDetail.textColor = MacTheme.Color.secondaryLabel
        heroChecked.font = MacTheme.Font.caption()
        heroChecked.textColor = MacTheme.Color.tertiaryLabel
        emptyLabel.font = MacTheme.Font.body()
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        statusLabel.font = MacTheme.Font.caption()
        statusLabel.textColor = MacTheme.Color.secondaryLabel
        for card in cards.values { card.applyTheme() }
    }

    private func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
    }
}
