import CodingAgentKit
import TailscodeCore
import TailscodeMetal
import UIKit

/// A shell on the machine a chat runs on, opened from that chat.
///
/// The shell is the server's, which is why a phone can have one at all: this screen draws what
/// the server sends and sends back what is typed. It is pushed like any other screen, so the
/// swipe that goes back goes back, and leaving it lets go of nothing: the shell, its folder and
/// its scrollback are there when it is opened again.
final class TerminalViewController: UIViewController {
    private let session: TerminalSession
    private let caption = UILabel()
    private let terminal = PhoneTerminalView(frame: .zero)

    init(session: TerminalSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Terminal")
        navigationItem.largeTitleDisplayMode = .never
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.secondaryLabel
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.inset = Theme.Spacing.m
        terminal.setFontSize(
            UIFontMetrics(forTextStyle: .body).scaledValue(for: traitCollection.horizontalSizeClass == .compact ? 12 : 13))
        view.addSubview(caption)
        view.addSubview(terminal)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            caption.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.m),
            caption.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.m),
            terminal.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Theme.Spacing.xs),
            terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        recolour()
        terminal.session = session
        session.onChange { [weak self] in
            DispatchQueue.main.async { self?.restate() }
        }
        session.onDirty { [weak self] in
            DispatchQueue.main.async { self?.terminal.requestFrame() }
        }
        restate()
        NotificationCenter.default.addObserver(
            self, selector: #selector(recolour), name: ThemeSelection.didChange, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.recolour() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminal.becomeFirstResponder()
        terminal.requestFrame()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        terminal.resignFirstResponder()
    }

    @objc private func recolour() {
        TerminalDesk.recolour()
        let colors = TerminalDesk.colors
        view.backgroundColor = UIColor(
            red: CGFloat((colors.background >> 16) & 0xff) / 255,
            green: CGFloat((colors.background >> 8) & 0xff) / 255,
            blue: CGFloat(colors.background & 0xff) / 255, alpha: 1)
        terminal.canvas = colors.background
    }

    private func restate() {
        let reading = session.reading
        caption.text = reading.caption
        navigationItem.title = reading.job ?? reading.shell ?? String(localized: "Terminal")
    }

    /// What the screen and the caption hold, for a check that has no eyes.
    var screenText: String { session.screen?.text ?? "" }

    /// Types as a person would, for a staged launch.
    func stage(_ text: String) {
        session.type(text)
    }
}

/// The terminal's picture with a phone's keyboard and fingers.
///
/// The keyboard on screen types through the text system, with a row above it for the keys it
/// lacks; a hardware keyboard's arrows, Escape, Tab and Control go to the terminal as keys. One
/// finger dragged scrolls, which a full-screen program hears as its own scrolling; a finger held
/// still and then moved selects, and lifting it offers Copy.
final class PhoneTerminalView: TerminalMetalView, UIKeyInput, UITextInputTraits, UIEditMenuInteractionDelegate {
    private let bar = TerminalKeyBar()
    private var scrolled: CGFloat = 0
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .default

    private static let named: [UIKeyboardHIDUsage: TerminalKey] = [
        .keyboardUpArrow: .arrowUp, .keyboardDownArrow: .arrowDown, .keyboardLeftArrow: .arrowLeft,
        .keyboardRightArrow: .arrowRight, .keyboardEscape: .escape, .keyboardTab: .tab,
        .keyboardHome: .home, .keyboardEnd: .end, .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown,
        .keyboardDeleteForward: .delete, .keyboardF1: .function(1), .keyboardF2: .function(2),
        .keyboardF3: .function(3), .keyboardF4: .function(4), .keyboardF5: .function(5),
        .keyboardF6: .function(6), .keyboardF7: .function(7), .keyboardF8: .function(8),
        .keyboardF9: .function(9), .keyboardF10: .function(10), .keyboardF11: .function(11),
        .keyboardF12: .function(12),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "terminal.screen"
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityLabel = String(localized: "Terminal")
        bar.onKey = { [weak self] key in self?.barKey(key) }
        addInteraction(editMenu)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
    }

    override var accessibilityValue: String? {
        get { session?.screen?.text }
        set {}
    }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            showsFocus = true
            session?.focus(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        showsFocus = false
        session?.focus(false)
        return super.resignFirstResponder()
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let session else { return }
        if bar.controlHeld, let letter = text.lowercased().first, text.count == 1 {
            bar.controlHeld = false
            session.press(TerminalKeyPress(key: .typing(letter), modifiers: .control, unshifted: letter))
            return
        }
        session.type(text.replacingOccurrences(of: "\n", with: "\r"))
    }

    func deleteBackward() {
        session?.press(TerminalKeyPress(key: .backspace))
    }

    private func barKey(_ key: TerminalKeyBar.Key) {
        switch key {
        case .press(let key):
            session?.press(TerminalKeyPress(key: key, modifiers: bar.controlHeld ? .control : []))
            bar.controlHeld = false
        case .text(let text):
            insertText(text)
        case .control:
            bar.controlHeld.toggle()
        case .paste:
            paste(nil)
        case .dismiss:
            _ = resignFirstResponder()
        }
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> TerminalModifiers {
        var modifiers: TerminalModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.alt) }
        return modifiers
    }

    /// A hardware keyboard's named keys and anything held with Control are keys for the
    /// terminal; everything else is left to the text system, which turns it into text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let session, let key = press.key, !key.modifierFlags.contains(.command) else {
                unhandled.insert(press)
                continue
            }
            let held = Self.modifiers(key.modifierFlags)
            if let named = Self.named[key.keyCode] {
                session.press(TerminalKeyPress(key: named, modifiers: held))
            } else if key.modifierFlags.contains(.control), let letter = key.charactersIgnoringModifiers.lowercased().first {
                var keys: TerminalModifiers = [.control]
                if held.contains(.shift) { keys.insert(.shift) }
                session.press(TerminalKeyPress(key: .typing(letter), modifiers: keys, unshifted: letter))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    @objc private func tapped() {
        if !isFirstResponder { _ = becomeFirstResponder() }
        session?.screen?.clearSelection()
        requestFrame()
    }

    /// A finger dragged is a wheel turned: whole rows are spent as the drag adds up to them.
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let session, let screen = session.screen else { return }
        if gesture.state == .began { scrolled = 0 }
        let travelled = gesture.translation(in: self).y
        let rows = Int(((scrolled - travelled) / rowHeight).rounded(.towardZero))
        guard rows != 0 else { return }
        scrolled -= CGFloat(rows) * rowHeight
        let at = pixel(gesture.location(in: self))
        let bytes = screen.wheel(rows: rows, modifiers: [], x: at.x, y: at.y)
        if bytes.isEmpty {
            requestFrame()
        } else {
            session.send(bytes)
        }
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard let screen = session?.screen else { return }
        let point = gesture.location(in: self)
        let at = pixel(point)
        switch gesture.state {
        case .began:
            Theme.Haptics.selection()
            screen.select(.press, x: at.x, y: at.y)
            screen.select(.release, x: at.x, y: at.y)
            screen.select(.press, x: at.x, y: at.y)
        case .changed:
            screen.select(.drag, x: at.x, y: at.y)
        case .ended, .cancelled:
            screen.select(.release, x: at.x, y: at.y)
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        default:
            break
        }
        requestFrame()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): return session?.screen?.hasSelection == true
        case #selector(paste(_:)): return UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)): return session != nil
        default: return false
        }
    }

    override func copy(_ sender: Any?) {
        guard let text = session?.screen?.selectionText, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        session?.screen?.clearSelection()
        requestFrame()
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        session?.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        session?.screen?.selectAll()
        requestFrame()
    }
}
