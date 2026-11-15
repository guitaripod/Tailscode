import AppKit
import MidgarCommerce
import MidgarCore
import TailscodeCore

/// The Pro window, opened by hand — from the menu, or from the one gate in the app when somebody
/// reaches for a second machine. Never on launch, never on a timer, and never in front of work: an
/// open-source app that nags is a fork waiting to happen. It leads with the person
/// (`ProPersonalDetails`) and lists what they get; nothing on it asks for anything. A copy that never
/// had a Pro week is offered one here as the default button, with the purchase beside it.
@MainActor
final class ProWindowController: NSWindowController {
    private static let openingWidth: CGFloat = 460
    private static let smallestContent = NSSize(width: 420, height: 240)
    /// Not `TailscodePro`: earlier builds let this window take its size from a view that had none, so it
    /// opened as a bare title bar and remembered that frame under the old name.
    private static let frameName = "TailscodePro2"

    private let column = FillingStack(views: [])
    private let scroll = NSScrollView()
    private let purchase = RowKit.ActionButton(title: Localized.text("Unlock Pro")) {}
    private let restore = RowKit.ActionButton(title: ProOffer.restoreTitle) {}
    private let status = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private var proProduct: StoreProduct?
    private var onAccess: (@MainActor () -> Void)?
    private var hasChosenSize = false
    private var sizedToPage: CGFloat?
    private var isLoading = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.openingWidth, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = ProOffer.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.smallestContent
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        hasChosenSize = window.rememberFrame(as: Self.frameName)
        restore.setAction { [weak self] in self?.restorePurchases() }
        status.isHidden = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(proChanged), name: ProAccess.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
    }

    /// A window closed without Pro forgets what it would have carried on with: an Ask to Buy approved
    /// hours later must not suddenly save a server or open Delegate.
    @objc private func closed() {
        onAccess = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A colour handed to a label is the theme it was handed under, and this window lives for the
    /// whole session — so a theme picked while it is open rebuilds the page around the buttons it
    /// already has, which keep their titles, their prices and whatever the status line was saying.
    @objc private func repaint() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        window?.contentView = makeContent()
        status.textColor = MacTheme.Color.secondaryLabel
        followPage()
    }

    /// Brings the window forward and sends `paywall.view` with `placement`, where it was opened from.
    /// A window already on screen is the same view brought forward, not a second one, so it is
    /// counted once, as the iPhone's sheet is.
    /// - Parameter onAccess: What brought the person here, carried on with once Pro is open — by the
    ///   week, a purchase or a restore — after this window has gone. Opened by hand, nothing waits
    ///   and the window stays to say what the person now has.
    func present(placement: MidgarSignal.Placement, onAccess: (@MainActor () -> Void)? = nil) {
        self.onAccess = onAccess
        if window?.isVisible != true {
            ReviewPromptPolicy.notePaywallShown()
            MidgarPaywallMoments.noteShown(placement: placement)
            fitToPage()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await load() }
    }

    /// Sizes a window nobody has resized to its page: as tall as the page is, never taller than
    /// the screen has room for, with the scroll view taking whatever does not fit.
    private func fitToPage() {
        guard let window, !hasChosenSize else { return }
        hasChosenSize = true
        window.setContentSize(NSSize(width: Self.openingWidth, height: Self.smallestContent.height))
        let height = pageHeight(in: window)
        window.setContentSize(NSSize(width: Self.openingWidth, height: height))
        window.center()
        sizedToPage = height
    }

    /// Keeps a window this page sized at the page's height as the page changes — a status line under
    /// the buttons, the offer giving way to what the person now has — growing and shrinking from its
    /// top edge. A window the person resized is theirs and stays as they left it.
    private func followPage() {
        guard let window, let sizedToPage,
            abs(window.contentRect(forFrameRect: window.frame).height - sizedToPage) < 1
        else { return }
        let height = pageHeight(in: window)
        guard abs(height - sizedToPage) >= 1 else { return }
        let content = NSRect(x: 0, y: 0, width: window.contentRect(forFrameRect: window.frame).width, height: height)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
        self.sizedToPage = height
    }

    /// How tall the content has to be to show the whole page at the window's width, within the
    /// screen's room and never under the window's smallest size.
    private func pageHeight(in window: NSWindow) -> CGFloat {
        window.contentView?.layoutSubtreeIfNeeded()
        let room = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        return min(max(column.frame.height, Self.smallestContent.height), room - 160)
    }

    private func makeContent() -> NSView {
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false

        let facts = ProPersonalDetails.Facts.onThisMac
        let isPro = ProAccess.shared.isPro
        column.addArrangedSubview(
            RowKit.wrapping(
                ProPersonalDetails.headline(facts, isPro: isPro), font: MacTheme.Ramp.font(.cardTitle),
                color: MacTheme.Color.label))
        if let subline = ProPersonalDetails.subline(facts, isPro: isPro) {
            column.addArrangedSubview(
                RowKit.wrapping(subline, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
        }
        for perk in ProPersonalDetails.perks(facts) { column.addArrangedSubview(perkRow(perk)) }

        if !isPro { addOffer() }

        let clip = RowKit.FlippedClip()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = column
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = MacTheme.Color.canvas
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
        return container
    }

    /// What a copy without Pro is asked, once: the week as the first button when it was never
    /// started, the purchase as the first button after that, and the way to restore under both.
    private func addOffer() {
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(MacTheme.Spacing.xl, after: last) }
        let offersWeek = ProAccess.shared.canStartProWeek
        if offersWeek {
            column.addArrangedSubview(
                RowKit.label(ProWeek.offerTitle, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label))
            column.addArrangedSubview(
                RowKit.wrapping(
                    ProWeek.offerBody, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
            let week = RowKit.ActionButton(title: ProWeek.startTitle) { [weak self] in self?.startWeek() }
            prominent(week)
            column.addArrangedSubview(week)
            column.setCustomSpacing(MacTheme.Spacing.s, after: week)
        } else if let endsAt = ProAccess.shared.proWeekEndsAt {
            column.addArrangedSubview(
                RowKit.wrapping(
                    ProWeek.runningLine(endsAt: endsAt), font: MacTheme.Ramp.font(.cardBody),
                    color: MacTheme.Color.accent))
        }
        purchase.controlSize = .large
        if offersWeek {
            purchase.keyEquivalent = ""
            purchase.bezelColor = nil
        } else {
            prominent(purchase)
        }
        column.addArrangedSubview(purchase)
        column.addArrangedSubview(status)
        restore.bezelStyle = .inline
        let restoreRow = NSStackView(views: [restore])
        restoreRow.orientation = .horizontal
        restoreRow.alignment = .centerY
        column.addArrangedSubview(restoreRow)
    }

    /// The button the page leads to: the accent, large, and the one Return presses.
    private func prominent(_ button: NSButton) {
        button.controlSize = .large
        button.bezelColor = MacTheme.Color.accent
        button.keyEquivalent = "\r"
    }

    private func perkRow(_ perk: ProOffer.Perk) -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: perk.symbol, accessibilityDescription: nil)
        symbol.contentTintColor = MacTheme.Color.accent
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let text = RowKit.wrapping(
            perk.text, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.label)
        let row = NSStackView(views: [symbol, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s
        return row
    }

    /// Starts the week with as many servers kept afterwards as are saved now, then carries on with
    /// what brought the person here, or redraws the page around the week.
    private func startWeek() {
        let servers = ServerDirectory.shared.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }.count
        guard ProAccess.shared.startProWeek(servers: servers) else { return }
        if !carryOn() { repaint() }
    }

    /// Closes the window and runs what brought the person here, once. Whether anything did.
    @discardableResult
    private func carryOn() -> Bool {
        guard let onAccess else { return false }
        self.onAccess = nil
        window?.close()
        onAccess()
        return true
    }

    @objc private func proChanged() {
        guard ProAccess.shared.isPro else { return }
        if !carryOn() { repaint() }
        say("")
    }

    /// The line under the buttons, gone when there is nothing to say so the page does not hold a gap.
    private func say(_ text: String) {
        status.stringValue = text
        status.isHidden = text.isEmpty
        followPage()
    }

    /// Whether a purchase or a restore is waiting on the App Store, so neither button can be pressed
    /// into a second one.
    private func setBusy(_ busy: Bool) {
        purchase.isEnabled = !busy && !isLoading
        restore.isEnabled = !busy
    }

    /// Asks the App Store for the price. The button reads "Unlock Pro" and waits until it has one;
    /// a store that does not answer turns it into the way to ask again, as on the iPhone.
    private func load() async {
        guard !ProAccess.shared.isPro, !isLoading else { return }
        isLoading = true
        purchase.isEnabled = false
        purchase.title = Localized.text("Unlock Pro")
        say("")
        let pro = await ProAccess.shared.proProduct()
        isLoading = false
        proProduct = pro
        guard !ProAccess.shared.isPro else { return }
        purchase.isEnabled = true
        if let pro {
            purchase.title = Localized.text("Unlock Pro · %@", pro.displayPrice)
            purchase.setAction { [weak self] in self?.buy(pro) }
        } else {
            purchase.title = Localized.text("Try again")
            purchase.setAction { [weak self] in Task { await self?.load() } }
            say(Localized.text("Couldn't reach the App Store. Check your connection and try again."))
        }
    }

    private func buy(_ product: StoreProduct) {
        say("")
        setBusy(true)
        Task {
            defer { setBusy(false) }
            do {
                switch try await ProAccess.shared.purchase(product, in: window) {
                case .success:
                    carryOn()
                case .pending:
                    say(Localized.text("Waiting on approval — this window can be closed."))
                case .cancelled:
                    break
                case .unverified:
                    say(Localized.text("That purchase could not be verified. Nothing was charged."))
                }
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    private func restorePurchases() {
        say(Localized.text("Checking…"))
        setBusy(true)
        Task {
            defer { setBusy(false) }
            do {
                switch try await ProAccess.shared.restore() {
                case .restored:
                    say("")
                    carryOn()
                case .nothingFound:
                    say(Localized.text("No purchase found on this Apple Account."))
                case .cancelled:
                    say("")
                }
            } catch {
                say(error.localizedDescription)
            }
        }
    }
}
