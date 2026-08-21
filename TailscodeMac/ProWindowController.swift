import AppKit
import StoreKit
import TailscodeCore

/// The Pro unlock and the tip jar, opened by hand — from the menu, or from the one gate in the app
/// when somebody reaches for a second machine. Never on launch, never on a timer, and never in
/// front of work: an open-source app that nags is a fork waiting to happen.
@MainActor
final class ProWindowController: NSWindowController {
    private let column = FillingStack(views: [])
    private let scroll = NSScrollView()
    private let purchase = RowKit.ActionButton(title: ProOffer.title) {}
    private let restore = RowKit.ActionButton(title: ProOffer.restoreTitle) {}
    private let status = RowKit.wrapping(
        "", font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.secondaryLabel)
    private let tips = NSStackView()
    private var proProduct: Product?

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(proChanged), name: MacProStore.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
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

        column.addArrangedSubview(
            RowKit.label(
                Localized.text("Support Tailscode"), font: MacTheme.Ramp.font(.cardTitle),
                color: MacTheme.Color.label))
        column.addArrangedSubview(
            RowKit.wrapping(
                ProOffer.pitch, font: MacTheme.Ramp.font(.cardBody),
                color: MacTheme.Color.secondaryLabel))
        for perk in ProOffer.perks { column.addArrangedSubview(perkRow(perk)) }

        purchase.keyEquivalent = "\r"
        column.addArrangedSubview(purchase)
        column.addArrangedSubview(status)

        column.addArrangedSubview(
            RowKit.label(
                ProOffer.tipHeading, font: MacTheme.Ramp.font(.sectionLabel),
                color: MacTheme.Color.secondaryLabel))
        tips.orientation = .horizontal
        tips.spacing = MacTheme.Spacing.s
        column.addArrangedSubview(tips)

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

    @objc private func proChanged() {
        guard MacProStore.shared.isPro else { return }
        purchase.title = ProOffer.thanks
        purchase.isEnabled = false
        status.stringValue = ""
    }

    private func load() async {
        let (pro, tipProducts) = await MacProStore.shared.products()
        proProduct = pro
        if MacProStore.shared.isPro {
            proChanged()
        } else if let pro {
            purchase.title = Localized.text("Unlock Pro · %@", pro.displayPrice)
            purchase.setAction { [weak self] in self?.buy(pro) }
        } else {
            purchase.isEnabled = false
            status.stringValue = Localized.text("The App Store is not answering right now.")
        }
        restore.setAction { [weak self] in self?.restorePurchases() }
        for view in tips.arrangedSubviews { view.removeFromSuperview() }
        for tip in tipProducts {
            let button = RowKit.ActionButton(title: tip.displayPrice) { [weak self] in
                self?.buy(tip)
            }
            tips.addArrangedSubview(button)
        }
        tips.addArrangedSubview(RowKit.spacer())
    }

    private func buy(_ product: Product) {
        status.stringValue = ""
        Task {
            do {
                switch try await MacProStore.shared.purchase(product) {
                case .success:
                    status.stringValue = Localized.text("Thank you ♥")
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
                try await MacProStore.shared.restore()
                status.stringValue =
                    MacProStore.shared.isPro
                    ? ProOffer.thanks
                    : Localized.text("No purchase found on this Apple Account.")
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
}
