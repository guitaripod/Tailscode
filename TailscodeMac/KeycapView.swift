import AppKit
import TailscodeCore

/// A run of keys as they are printed on a keyboard: a small rounded plate per key, with the dim
/// words that join them ("then" between the keys of a sequence, "or" between two bindings) set
/// between. The whole run is one view drawn in one pass and measured once, because a settings
/// page carries well over a hundred of them and a plate that is a view with constraints of its
/// own made the page cost several hundred milliseconds to lay out.
@MainActor
final class KeycapView: NSView {
    enum Tone {
        case plain
        case warning
    }

    enum Item {
        case cap(String, Tone)
        case word(String)

        var text: String {
            switch self {
            case .cap(let legend, _): return legend
            case .word(let word): return word
            }
        }
    }

    private struct Placed {
        let item: Item
        let x: CGFloat
        let width: CGFloat
    }

    private static let gap: CGFloat = 4
    private static let padding: CGFloat = 6
    private let placed: [Placed]
    private let size: NSSize
    private let textHeight: CGFloat

    init(_ items: [Item]) {
        let font = MacTheme.Ramp.font(.panelFootnote)
        var x: CGFloat = 0
        var run: [Placed] = []
        var height: CGFloat = 0
        for item in items {
            let measured = (item.text as NSString).size(withAttributes: [.font: font])
            height = max(height, ceil(measured.height))
            let width: CGFloat
            switch item {
            case .cap: width = max(ceil(measured.height) + 4, ceil(measured.width) + Self.padding * 2)
            case .word: width = ceil(measured.width)
            }
            run.append(Placed(item: item, x: x, width: width))
            x += width + Self.gap
        }
        placed = run
        textHeight = height
        size = NSSize(width: max(0, x - Self.gap), height: height + 4)
        super.init(frame: NSRect(origin: .zero, size: size))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(items.map(\.text).joined(separator: " "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = MacTheme.Ramp.font(.panelFootnote)
        let top = (bounds.height - textHeight) / 2
        for each in placed where each.x + each.width >= dirtyRect.minX && each.x <= dirtyRect.maxX {
            switch each.item {
            case .word(let word):
                (word as NSString).draw(
                    at: NSPoint(x: each.x, y: top),
                    withAttributes: [.font: font, .foregroundColor: MacTheme.Color.tertiaryLabel])
            case .cap(let legend, let tone):
                let warning = tone == .warning
                let plate = NSBezierPath(
                    roundedRect: NSRect(x: each.x, y: 0, width: each.width, height: bounds.height)
                        .insetBy(dx: 0.5, dy: 0.5),
                    xRadius: 5, yRadius: 5)
                MacTheme.Color.canvasRaised.setFill()
                plate.fill()
                (warning ? MacTheme.Color.warning : MacTheme.Color.separator).setStroke()
                plate.lineWidth = 1
                plate.stroke()
                let measured = (legend as NSString).size(withAttributes: [.font: font])
                (legend as NSString).draw(
                    at: NSPoint(x: each.x + (each.width - measured.width) / 2, y: top),
                    withAttributes: [
                        .font: font,
                        .foregroundColor: warning ? MacTheme.Color.warning : MacTheme.Color.label,
                    ])
            }
        }
    }
}

/// The runs of caps the keyboard page and the capture sheet both draw a binding with, so a key
/// reads the same where it is listed and where it is changed.
@MainActor
enum Keycaps {
    private static func items(for chord: KeyChord) -> [KeycapView.Item] {
        chord.caps(on: .apple).map { .cap($0, .plain) }
    }

    private static func items(for chords: [KeyChord]) -> [KeycapView.Item] {
        var run: [KeycapView.Item] = []
        for (index, each) in chords.enumerated() {
            if index > 0 { run.append(.word(Localized.text("then"))) }
            run += items(for: each)
        }
        return run
    }

    /// One binding: a single chord, or two with "then" between them. A spec nothing can read is
    /// shown as it was written, in the warning tone, so a hand-edited file never hides a key that
    /// the page cannot draw.
    static func key(_ key: ShortcutKey) -> KeycapView {
        guard key.isReadable else { return KeycapView([.cap(key.spec, .warning)]) }
        return KeycapView(items(for: key.chords))
    }

    /// Every key an action answers to, with "or" between them, or a dim "Not set".
    static func keys(_ keys: [ShortcutKey]) -> KeycapView {
        guard !keys.isEmpty else { return KeycapView([.word(Localized.text("Not set"))]) }
        var run: [KeycapView.Item] = []
        for (index, each) in keys.enumerated() {
            if index > 0 { run.append(.word(Localized.text("or"))) }
            run += each.isReadable ? items(for: each.chords) : [.cap(each.spec, .warning)]
        }
        return KeycapView(run)
    }

    /// The caps of chords that are still being pressed, before any binding exists.
    static func pressed(_ chords: [KeyChord]) -> KeycapView {
        KeycapView(items(for: chords))
    }
}
