import AppKit
import TailscodeCore

/// The toolbar's way in to video, and the render's own mark while one is out.
///
/// Video reached through a menu item alone is a preference; reached through a control that sits with
/// the window's other primary actions it is what it actually is — an action, the same weight as
/// starting a chat. What it promises differs before a renderer exists and after, and while the other
/// machine is working it wears the render's light round its own edge, so a person who closed the Studio
/// can still see where it is, and stays lit after it ends until the ending has been looked at. Every
/// word and the symbol are `ForgeEntryPoint`'s, and every frame of the light is `ForgeLight`'s.
@MainActor
final class ForgeMarkButton: NSButton {
    private let ring = ForgeRingView()

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: ForgeEntryPoint.symbol,
            accessibilityDescription: ForgeEntryPoint.title)
        setButtonType(.momentaryPushIn)
        bezelStyle = .toolbar
        isBordered = true
        self.target = target
        self.action = action
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The mark follows the window, not the process. Watching from `init` and never letting go left
    /// every control ever built being called back for the life of the app — invisible while it only
    /// costs a call, and not invisible at all once the runner's table, which is keyed by the
    /// object's address, hands a dead button's slot to whatever is allocated there next. A toolbar
    /// takes an item's view out of the hierarchy and puts it back, so this is the hook that says
    /// when the ring is worth keeping current: on the way in it watches and draws itself at once,
    /// on the way out it lets go.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            ForgeRunner.shared.unwatch(self)
            return
        }
        ForgeRunner.shared.watch(self) { [weak self] in self?.render() }
        render()
    }

    /// A tooltip is not read aloud, so what this control promises goes into the accessibility label
    /// as well — and the label says where the render is, because the ring alone says it only to
    /// somebody who can see it.
    func render() {
        let light = ForgeRunner.shared.light
        ring.show(light)
        toolTip = ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil, light: light)
        setAccessibilityLabel(ForgeEntryPoint.accessibilityLabel(light: light))
    }

    /// The ring itself, for a harness that proves what the light says without a picture of it.
    var ringView: ForgeRingView { ring }
}
