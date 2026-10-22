import AppKit
import TailscodeCore

/// The band as its own glass capsule between transcript and composer: a line of clickable facts,
/// exactly the Linux band's semantics. Segments are diffed by id and kind and updated in place —
/// this redraws every second while a turn runs, and a rebuilt control would close the menu
/// someone is reading. Menus and action clicks read the newest facts at the moment they fire, so
/// a list opened mid-turn is the list as it is now. The notice rides the trailing edge and
/// truncates first: it must never push a live fact off the band.
///
/// A fact holds still. Each keeps room for the widest it has been in this conversation
/// (`StatusBandSlots`, as a minimum a narrow pane can still compress), the leading mark owns a slot
/// as wide as the widest mark in the vocabulary, and the context fact reserves the ring's room
/// whether or not a ring is drawn — so the clock, the share and the counts change their own words
/// and nothing beside them moves. Only what changed is written: a tick that says the same thing
/// again costs no layout.
@MainActor
final class StatusBandView: NSView {
    var perform: ((StatusFacts.Action) -> Void)?
    /// False after a render that produced any segment or notice — the owner collapses the glass
    /// around an empty band rather than floating a blank sliver.
    private(set) var hasContent = false

    /// The band is one chip tall and every control in it is as tall as the band, so the whole strip
    /// answers a press rather than the thirteen points its words occupy.
    fileprivate static var height: CGFloat {
        let font = MacTheme.Ramp.font(.segment)
        let line = ceil(font.ascender - font.descender + font.leading + 8)
        return max(CGFloat(ChatChrome.chip(on: .pointer).height), line)
    }

    private lazy var minimumHeight = stack.heightAnchor.constraint(
        greaterThanOrEqualToConstant: Self.height)

    private let stack = NSStackView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private var segments: [StatusFacts.Segment] = []
    private var widgets: [String: NSView] = [:]
    private var kinds: [String: String] = [:]
    private var written: [String: Written] = [:]
    private var ranks: [String: Int] = [:]
    private var slots = StatusBandSlots()
    /// One hand per fact that is about something happening. Kept beside the widgets so a segment
    /// that leaves the band takes its clock with it.
    private var pulses: [String: ActivityPulse] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MacTheme.Spacing.m
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: MacTheme.Spacing.m, bottom: 0, right: MacTheme.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            minimumHeight,
        ])

        noticeLabel.font = MacTheme.Ramp.font(.segment)
        noticeLabel.textColor = MacTheme.Color.onGlassSecondary
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        noticeLabel.isHidden = true
        stack.addArrangedSubview(RowKit.spacer())
        stack.addArrangedSubview(noticeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A pulse refuses to run without a window and will not restart on its own, and the tiling host
    /// takes every pane's view out of the hierarchy and puts it back whenever the tree is rebuilt —
    /// so splitting a pane mid-turn would leave the running turn's segment perfectly still, which is
    /// how a reader is told a turn has stopped.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for pulse in pulses.values { pulse.windowChanged() }
    }

    struct Placement {
        let id: String
        let frame: NSRect
        let natural: CGFloat
        let image: CGFloat
    }

    /// Where each fact sits on the band, in order, and how wide its words alone would make it, for
    /// the selftest that holds the band still.
    var placements: [Placement] {
        segments.compactMap { segment in
            guard let view = widgets[segment.id] as? (NSView & HeldWidth) else { return nil }
            return Placement(
                id: segment.id, frame: view.frame, natural: view.naturalWidth,
                image: (view as? NSButton)?.image?.size.width ?? 0)
        }
    }

    /// The facts belong to one conversation's band: showing another starts the widths over, so a
    /// long tool name from one chat does not leave room in the next.
    func resetSlots() {
        slots.reset()
        applyHeldWidths()
    }

    /// One frame of a sweeping mark, written in place of the segment's leading glyph. The mark owns
    /// a slot as wide as the widest glyph there is, so a frame repaints and never re-measures.
    func sweep(_ frame: String, segment id: String) {
        guard let segment = segments.first(where: { $0.id == id }), let view = widgets[id]
        else { return }
        write(frame + segment.text.dropFirst(), to: view, segment: segment)
    }

    override func layout() {
        super.layout()
        applyHeldWidths()
    }

    /// Held widths are read against the band's width now, so a narrower pane lowers the room a fact
    /// keeps and a wider one gives back what was clamped.
    private func applyHeldWidths() {
        let band = bandWidth
        for (id, view) in widgets {
            (view as? HeldWidth)?.heldWidth = CGFloat(slots.width(of: id, in: band))
        }
    }

    private var bandWidth: Double? { bounds.width > 0 ? Double(bounds.width) : nil }

    private func hold(_ view: NSView, id: String) {
        guard let view = view as? HeldWidth else { return }
        let band = bandWidth
        slots.widen(id, to: Double(view.naturalWidth), in: band)
        view.heldWidth = CGFloat(slots.width(of: id, in: band))
    }

    func render(facts: StatusFacts?, notice: String?) {
        let interval = Pace.signposter.beginInterval("band render")
        defer { Pace.signposter.endInterval("band render", interval) }
        let segments = facts?.segments ?? []
        self.segments = segments
        let wanted = Set(segments.map(\.id))

        for (id, view) in widgets where !wanted.contains(id) {
            view.removeFromSuperview()
            widgets[id] = nil
            kinds[id] = nil
            written[id] = nil
            ranks[id] = nil
            pulses[id]?.stop()
            pulses[id] = nil
        }

        var index = 0
        for segment in segments {
            let tag = Self.kindTag(segment)
            if let view = widgets[segment.id], kinds[segment.id] == tag {
                update(view, segment: segment)
                index += 1
                continue
            }
            if let stale = widgets[segment.id] { stale.removeFromSuperview() }
            pulses[segment.id]?.stop()
            written[segment.id] = nil
            ranks[segment.id] = nil
            let view = make(segment)
            stack.insertArrangedSubview(view, at: index)
            widgets[segment.id] = view
            kinds[segment.id] = tag
            written[segment.id] = Written(segment)
            hold(view, id: segment.id)
            let id = segment.id
            pulses[id] = ActivityPulse(view: view) { [weak self] frame in
                self?.sweep(frame, segment: id)
            }
            animate(segment)
            index += 1
        }
        for (rank, segment) in segments.enumerated() where ranks[segment.id] != rank {
            guard let view = widgets[segment.id] else { continue }
            ranks[segment.id] = rank
            stack.setVisibilityPriority(Self.visibility(rank: rank), for: view)
        }

        let font = MacTheme.Ramp.font(.segment)
        if noticeLabel.font != font { noticeLabel.font = font }
        let height = Self.height
        if minimumHeight.constant != height { minimumHeight.constant = height }
        let words = notice ?? ""
        if noticeLabel.stringValue != words { noticeLabel.stringValue = words }
        noticeLabel.isHidden = words.isEmpty
        hasContent = !segments.isEmpty || !words.isEmpty
    }

    /// A pane too narrow for every fact drops them from the end rather than holding the window
    /// wide: the facts lead with what the conversation is doing, and the phase is never dropped.
    private static func visibility(rank: Int) -> NSStackView.VisibilityPriority {
        rank == 0 ? .mustHold : NSStackView.VisibilityPriority(rawValue: Float(max(1, 900 - rank)))
    }

    private static func kindTag(_ segment: StatusFacts.Segment) -> String {
        switch segment.kind {
        case .plain: return "plain"
        case .act: return "act"
        case .menu: return "menu"
        }
    }

    /// The meanings keep the palette's own colours; the neutral register does not. This whole band
    /// sits on a pane of glass, which flips light↔dark against what is behind it and lends its
    /// vibrancy only to the system inks — a palette hex in the dim slot would do neither and read at
    /// a fraction of the contrast the rest of the capsule has.
    private static func color(for css: String) -> NSColor {
        switch css {
        case "seg-live": return MacTheme.Color.accent
        case "seg-warn": return MacTheme.Color.warning
        case "seg-error": return MacTheme.Color.danger
        case "seg-offline": return MacTheme.Color.onGlassSecondary
        case "seg-agents": return MacTheme.Color.info
        case "seg-goal": return MacTheme.Color.mark
        default: return MacTheme.Color.onGlassSecondary
        }
    }

    /// What a segment last put on its view. A tick that would write the same thing again is not
    /// written: setting a title invalidates the control and so costs a layout pass, and every fact
    /// but the clock says the same words as a second ago.
    private struct Written: Equatable {
        let text: String
        let css: String
        let parts: [GitBadgePart]?
        let meter: Double?
        let icon: ActivityIcon?
        let slot: CGFloat

        @MainActor
        init(_ segment: StatusFacts.Segment) {
            text = segment.text
            css = segment.css
            parts = segment.parts
            meter = segment.meter
            icon = segment.icon
            slot = Self.slot(for: segment)
        }

        @MainActor
        static func slot(for segment: StatusFacts.Segment) -> CGFloat {
            StatusBandView.wearsGlyphSlot(segment) ? GlyphSlot.current().width : 0
        }
    }

    /// The facts that lead with a mark of the activity vocabulary, and so with a slot sized for the
    /// widest of them: the turn's phase, what is queued behind it and the agents out.
    fileprivate static func wearsGlyphSlot(_ segment: StatusFacts.Segment) -> Bool {
        segment.icon != nil || segment.id == "agents"
    }

    private static func title(
        _ text: String, css: String, slotted: Bool = false
    ) -> NSAttributedString {
        let font = MacTheme.Ramp.font(.segment)
        let title = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color(for: css)])
        guard slotted, let glyph = text.first.map(String.init) else { return title }
        let kern = GlyphSlot.current().kern(for: glyph)
        if kern > 0 {
            title.addAttribute(
                .kern, value: kern, range: NSRange(location: 0, length: (glyph as NSString).length))
        }
        return title
    }

    private func update(_ view: NSView, segment: StatusFacts.Segment) {
        let now = Written(segment)
        guard written[segment.id] != now else { return }
        written[segment.id] = now
        write(Self.words(segment), to: view, segment: segment)
        name(view, for: segment)
        ring(segment, on: view)
        hold(view, id: segment.id)
        animate(segment)
    }

    /// What a screen reader is told, set from the segment's words and never from the drawn title: a
    /// sweeping segment rewrites that title with a new glyph every frame, and a name that changed
    /// sixty times a second would be read as sixty.
    private func name(_ view: NSView, for segment: StatusFacts.Segment) {
        let spoken = Self.spoken(segment)
        if view.accessibilityLabel() != spoken { view.setAccessibilityLabel(spoken) }
    }

    private static func spoken(_ segment: StatusFacts.Segment) -> String {
        let text =
            segment.icon == nil && symbol(for: segment) == nil
            ? segment.text : String(segment.text.dropFirst())
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The SF Symbol a segment wears in place of the character Core leads its words with, for the
    /// two range chips whose glyphs the text clients draw as characters.
    private static func symbol(for segment: StatusFacts.Segment) -> String? {
        switch segment.id {
        case "wall": return "clock"
        case "cache": return "snowflake"
        default: return nil
        }
    }

    /// What a segment's button says: its words, less the leading character when a symbol is
    /// drawn in front of them instead.
    private static func words(_ segment: StatusFacts.Segment) -> String {
        guard symbol(for: segment) != nil else { return segment.text }
        return String(segment.text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static let ringSlot = NSImage(
        size: NSSize(width: ringDiameter, height: ringDiameter), flipped: false
    ) { _ in true }

    fileprivate static let ringDiameter: CGFloat = 11

    private static func symbolImage(_ name: String, ink: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: MacTheme.Ramp.font(.segment).pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    /// A segment about how full something is wears a ring filled that far, in its own ink, drawn
    /// fresh on every update because the fraction is the whole of what it says. The image sits
    /// before the words the way the activity icon does on a live segment.
    private func ring(_ segment: StatusFacts.Segment, on view: NSView) {
        guard let button = view as? BandButton else { return }
        if let name = Self.symbol(for: segment) {
            button.image = Self.symbolImage(name, ink: Self.color(for: segment.css))
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            return
        }
        guard let fraction = segment.meter else {
            button.image = segment.id == "context" ? Self.ringSlot : nil
            button.imagePosition = segment.id == "context" ? .imageLeading : .noImage
            return
        }
        button.image = ContextRing.image(
            fraction: fraction, ink: Self.color(for: segment.css), diameter: Self.ringDiameter,
            stroke: 2)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    /// A segment that arrives as runs is written run by run, each in the colour of what it means —
    /// a branch, what it owes its upstream, what the tree is holding — because one colour over all
    /// of it makes a conflict read as another number.
    private func write(_ text: String, to view: NSView, segment: StatusFacts.Segment) {
        let rendered =
            segment.parts.map(Self.tinted)
            ?? Self.title(text, css: segment.css, slotted: Self.wearsGlyphSlot(segment))
        if let label = view as? NSTextField {
            label.attributedStringValue = rendered
        } else if let button = view as? BandButton {
            button.attributedTitle = rendered
        }
    }

    private static func tinted(_ parts: [GitBadgePart]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = MacTheme.Ramp.font(.segment)
        for part in parts {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(
                NSAttributedString(
                    string: part.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: part.tone == .neutral
                            ? MacTheme.Color.onGlassSecondary : part.tone.color,
                    ]))
        }
        return text
    }

    /// A fact about something happening moves the way that thing moves; a fact that is a number
    /// holds still. The band's words tick once a second underneath, so the light is the only thing
    /// that is continuous.
    private func animate(_ segment: StatusFacts.Segment) {
        pulses[segment.id]?.apply(segment.icon)
    }

    private func make(_ segment: StatusFacts.Segment) -> NSView {
        switch segment.kind {
        case .plain:
            let label = BandLabel(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.attributedStringValue =
                segment.parts.map(Self.tinted)
                ?? Self.title(
                    Self.words(segment), css: segment.css, slotted: Self.wearsGlyphSlot(segment))
            label.setContentCompressionResistancePriority(.init(700), for: .horizontal)
            name(label, for: segment)
            return label
        case .act:
            let id = segment.id
            let button = BandButton { [weak self] in
                guard let self,
                    let action = self.segments.first(where: { $0.id == id })?.action
                else { return }
                self.perform?(action)
            }
            button.attributedTitle =
                segment.parts.map(Self.tinted)
                ?? Self.title(
                    Self.words(segment), css: segment.css, slotted: Self.wearsGlyphSlot(segment))
            ring(segment, on: button)
            button.setAccessibilityRole(.button)
            button.setAccessibilityHelp(Localized.text("Opens details"))
            name(button, for: segment)
            return button
        case .menu:
            let id = segment.id
            let button = BandButton {}
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                let rows = self.segments.first { $0.id == id }?.rows ?? []
                guard !rows.isEmpty else { return }
                let menu = NSMenu()
                for row in rows {
                    if let action = row.action {
                        let perform = self.perform
                        let item = ClosureMenuItem(title: row.title) { perform?(action) }
                        if let detail = row.detail { item.subtitle = detail }
                        menu.addItem(item)
                    } else {
                        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                        item.isEnabled = false
                        if let detail = row.detail { item.subtitle = detail }
                        menu.addItem(item)
                    }
                }
                menu.popUp(
                    positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
            button.attributedTitle = Self.title(
                segment.text, css: segment.css, slotted: Self.wearsGlyphSlot(segment))
            button.setAccessibilityRole(.menuButton)
            button.setAccessibilityHelp(Localized.text("Opens a list"))
            name(button, for: segment)
            return button
        }
    }
}

/// A quiet text button for the band: no bezel, its meaning re-read from the latest facts at the
/// moment it is clicked — the title under the pointer may be a second newer than the closure
/// that made it.
@MainActor
private final class BandButton: NSButton, HeldWidth {
    var onClick: (() -> Void)?
    var heldWidth: CGFloat = 0 {
        didSet { if oldValue != heldWidth { invalidateIntrinsicContentSize() } }
    }
    var naturalWidth: CGFloat { super.intrinsicContentSize.width }

    init(onClick: @escaping () -> Void = {}) {
        self.onClick = onClick
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        setContentCompressionResistancePriority(.init(700), for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(naturalWidth, heldWidth), height: StatusBandView.height)
    }

    @objc private func fire() {
        onClick?()
    }
}

/// A fact that keeps the room of the widest it has been: the width its words alone ask for, and the
/// least it will take. Held as a minimum on the intrinsic size rather than a constraint, so the
/// stack still compresses or detaches it in a pane too narrow, and a hidden fact holds nothing the
/// window's width would have to answer to.
@MainActor
protocol HeldWidth: AnyObject {
    var heldWidth: CGFloat { get set }
    var naturalWidth: CGFloat { get }
}

@MainActor
private final class BandLabel: NSTextField, HeldWidth {
    var heldWidth: CGFloat = 0 {
        didSet { if oldValue != heldWidth { invalidateIntrinsicContentSize() } }
    }
    var naturalWidth: CGFloat { super.intrinsicContentSize.width }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(naturalWidth, heldWidth), height: super.intrinsicContentSize.height)
    }
}

/// The room the leading mark keeps: as wide as the widest glyph in the vocabulary, in the band's
/// own font. A mark's advance is the font's only when the font has the glyph — ⚒ and the half
/// circles of a sweep come from a fallback face — so the slot is measured here, once per font, and
/// each mark is padded up to it with a kern.
@MainActor
private final class GlyphSlot {
    let width: CGFloat
    private let font: NSFont
    private var advances: [String: CGFloat] = [:]

    private static var cache: [String: GlyphSlot] = [:]

    static func current() -> GlyphSlot {
        let font = MacTheme.Ramp.font(.segment)
        let key = "\(font.fontName) \(font.pointSize)"
        if let held = cache[key] { return held }
        let slot = GlyphSlot(font: font)
        cache[key] = slot
        return slot
    }

    private init(font: NSFont) {
        self.font = font
        var widest: CGFloat = 0
        var advances: [String: CGFloat] = [:]
        for glyph in StatusBandSlots.leadingGlyphs {
            let advance = Self.advance(of: glyph, in: font)
            advances[glyph] = advance
            widest = max(widest, advance)
        }
        self.advances = advances
        width = widest
    }

    func kern(for glyph: String) -> CGFloat {
        let advance = advances[glyph] ?? Self.advance(of: glyph, in: font)
        return max(0, width - advance)
    }

    private static func advance(of glyph: String, in font: NSFont) -> CGFloat {
        NSAttributedString(string: glyph, attributes: [.font: font]).size().width
    }
}
