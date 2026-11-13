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
    private let column = FillingStack(views: [])
    private let scroll = NSScrollView()
    private let purchase = RowKit.ActionButton(title: ProOffer.title) {}
    private let restore = RowKit.ActionButton(title: ProOffer.restoreTitle) {}
    private let status = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private var proProduct: StoreProduct?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = ProOffer.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 420)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentViewController = NSViewController(nibName: nil, bundle: nil)
        window.contentViewController?.view = makeContent()
        window.center()
        window.rememberFrame(as: "TailscodePro")
        NotificationCenter.default.addObserver(
            self, selector: #selector(proChanged), name: ProAccess.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(repaint), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A colour handed to a label is the theme it was handed under, and this window lives for the
    /// whole session — so a theme picked while it is open rebuilds the page around the buttons it
    /// already has, which keep their titles, their prices and whatever the status line was saying.
    @objc private func repaint() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        window?.contentViewController?.view = makeContent()
        status.textColor = MacTheme.Color.secondaryLabel
    }

    /// Brings the window forward and sends `paywall.view` with `placement`, where it was opened from.
    /// A window already on screen is the same view brought forward, not a second one, so it is
    /// counted once, as the iPhone's sheet is.
    func present(placement: MidgarSignal.Placement) {
        if window?.isVisible != true {
            ReviewPromptPolicy.notePaywallShown()
            MidgarPaywallMoments.noteShown(placement: placement)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await load() }
    }

    private func makeContent() -> NSView {
        column.spacing = MacTheme.Spacing.m
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.l)
        column.translatesAutoresizingMaskIntoConstraints = false

        let facts = ProPersonalDetails.Facts.onThisMac
        column.addArrangedSubview(
            RowKit.wrapping(
                ProPersonalDetails.headline(facts), font: MacTheme.Ramp.font(.cardTitle),
                color: MacTheme.Color.label))
        column.addArrangedSubview(
            RowKit.wrapping(
                ProOffer.pitch, font: MacTheme.Ramp.font(.cardBody),
                color: MacTheme.Color.secondaryLabel))
        for perk in ProPersonalDetails.perks(facts) { column.addArrangedSubview(perkRow(perk)) }

        if ProAccess.shared.canStartProWeek {
            column.addArrangedSubview(
                RowKit.label(ProWeek.offerTitle, font: MacTheme.Ramp.font(.cardTitle), color: MacTheme.Color.label))
            column.addArrangedSubview(
                RowKit.wrapping(
                    ProWeek.offerBody, font: MacTheme.Ramp.font(.cardBody), color: MacTheme.Color.secondaryLabel))
            let week = RowKit.ActionButton(title: ProWeek.startTitle) { [weak self] in self?.startWeek() }
            week.keyEquivalent = "\r"
            column.addArrangedSubview(week)
            purchase.keyEquivalent = ""
        } else {
            if let endsAt = ProAccess.shared.proWeekEndsAt {
                column.addArrangedSubview(
                    RowKit.wrapping(
                        ProWeek.runningLine(endsAt: endsAt), font: MacTheme.Ramp.font(.cardBody),
                        color: MacTheme.Color.accent))
            }
            purchase.keyEquivalent = "\r"
        }
        column.addArrangedSubview(purchase)
        column.addArrangedSubview(status)

        restore.bezelStyle = .inline
        column.addArrangedSubview(restore)

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

    /// Starts the week with as many servers kept afterwards as are saved now, and redraws the page around it.
    private func startWeek() {
        let servers = ServerDirectory.shared.savedProfiles.filter { !$0.id.hasPrefix(DemoWorld.profilePrefix) }.count
        guard ProAccess.shared.startProWeek(servers: servers) else { return }
        repaint()
    }

    @objc private func proChanged() {
        guard ProAccess.shared.isPro else { return }
        purchase.title = ProOffer.owned
        purchase.isEnabled = false
        status.stringValue = ""
    }

    private func load() async {
        let pro = await ProAccess.shared.proProduct()
        proProduct = pro
        if ProAccess.shared.isPro {
            proChanged()
        } else if let pro {
            purchase.title = Localized.text("Unlock Pro · %@", pro.displayPrice)
            purchase.setAction { [weak self] in self?.buy(pro) }
        } else {
            purchase.isEnabled = false
            status.stringValue = Localized.text("The App Store is not answering right now.")
        }
        restore.setAction { [weak self] in self?.restorePurchases() }
    }

    private func buy(_ product: StoreProduct) {
        status.stringValue = ""
        Task {
            do {
                switch try await ProAccess.shared.purchase(product, in: window) {
                case .success:
                    status.stringValue = ProOffer.owned
                case .pending:
                    status.stringValue = Localized.text(
                        "Waiting on approval — this window can be closed.")
                case .cancelled:
                    break
                case .unverified:
                    status.stringValue = Localized.text(
                        "That purchase could not be verified. Nothing was charged.")
                }
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    private func restorePurchases() {
        status.stringValue = Localized.text("Checking…")
        Task {
            do {
                switch try await ProAccess.shared.restore() {
                case .restored: status.stringValue = ProOffer.owned
                case .nothingFound:
                    status.stringValue = Localized.text("No purchase found on this Apple Account.")
                case .cancelled: status.stringValue = ""
                }
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
