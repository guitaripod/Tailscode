import AppKit
import TailscodeCore

/// The band as its own glass capsule between transcript and composer: a line of clickable facts,
/// exactly the Linux band's semantics. Segments are diffed by id and kind and updated in place —
/// this redraws every second while a turn runs, and a rebuilt control would close the menu
/// someone is reading. Menus and action clicks read the newest facts at the moment they fire, so
/// a list opened mid-turn is the list as it is now. The notice rides the trailing edge and
/// truncates first: it must never push a live fact off the band.
@MainActor
final class StatusBandView: NSView {
    var perform: ((StatusFacts.Action) -> Void)?
    /// False after a render that produced any segment or notice — the owner collapses the glass
    /// around an empty band rather than floating a blank sliver.
    private(set) var hasContent = false

    private let stack = NSStackView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private var facts = StatusFacts()
    private var widgets: [String: NSView] = [:]
    private var kinds: [String: String] = [:]
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
            top: 5, left: MacTheme.Spacing.m, bottom: 5, right: MacTheme.Spacing.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        noticeLabel.font = MacTheme.Font.mono(11)
        noticeLabel.textColor = MacTheme.Color.secondaryLabel
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        noticeLabel.isHidden = true
        stack.addArrangedSubview(RowKit.spacer())
        stack.addArrangedSubview(noticeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func render(facts: StatusFacts?, notice: String?) {
        self.facts = facts ?? StatusFacts()
        let segments = facts?.segments ?? []
        let wanted = Set(segments.map(\.id))

        for (id, view) in widgets where !wanted.contains(id) {
            view.removeFromSuperview()
            widgets[id] = nil
            kinds[id] = nil
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
            let view = make(segment)
            stack.insertArrangedSubview(view, at: index)
            widgets[segment.id] = view
            kinds[segment.id] = tag
            pulses[segment.id] = ActivityPulse(view: view) { [weak self, weak view] frame in
                guard let self, let view,
                    let text = self.facts.segments.first(where: { $0.id == segment.id })?.text
                else { return }
                self.write(frame + text.dropFirst(), to: view, css: segment.css)
            }
            animate(segment)
            index += 1
        }

        noticeLabel.stringValue = notice ?? ""
        noticeLabel.isHidden = notice?.isEmpty != false
        hasContent = !segments.isEmpty || notice?.isEmpty == false
    }

    private static func kindTag(_ segment: StatusFacts.Segment) -> String {
        switch segment.kind {
        case .plain: return "plain"
        case .act: return "act"
        case .menu: return "menu"
        }
    }

    private static func color(for css: String) -> NSColor {
        switch css {
        case "seg-live": return MacTheme.Color.accent
        case "seg-warn": return MacTheme.Color.warning
        case "seg-error": return MacTheme.Color.danger
        case "seg-offline": return MacTheme.Color.secondaryLabel
        case "seg-agents": return MacTheme.Color.info
        case "seg-goal": return MacTheme.Color.mark
        default: return MacTheme.Color.secondaryLabel
        }
    }

    private static func title(_ text: String, css: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: MacTheme.Font.mono(11), .foregroundColor: color(for: css)])
    }

    private func update(_ view: NSView, segment: StatusFacts.Segment) {
        write(segment.text, to: view, css: segment.css, parts: segment.parts)
        animate(segment)
    }

    /// A segment that arrives as runs is written run by run, each in the colour of what it means —
    /// a branch, what it owes its upstream, what the tree is holding — because one colour over all
    /// of it makes a conflict read as another number.
    private func write(
        _ text: String, to view: NSView, css: String, parts: [GitBadgePart]? = nil
    ) {
        let rendered = parts.map(Self.tinted) ?? Self.title(text, css: css)
        if let label = view as? NSTextField {
            label.attributedStringValue = rendered
        } else if let button = view as? BandButton {
            button.attributedTitle = rendered
        }
    }

    private static func tinted(_ parts: [GitBadgePart]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = MacTheme.Font.mono(11)
        for part in parts {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(
                NSAttributedString(
                    string: part.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: part.tone == .neutral
                            ? MacTheme.Color.secondaryLabel : part.tone.color,
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
            let label = RowKit.label(
                segment.text, font: MacTheme.Font.mono(11), color: Self.color(for: segment.css))
            if let parts = segment.parts { label.attributedStringValue = Self.tinted(parts) }
            label.setContentCompressionResistancePriority(.init(700), for: .horizontal)
            return label
        case .act:
            let id = segment.id
            let button = BandButton { [weak self] in
                guard let self,
                    let action = self.facts.segments.first(where: { $0.id == id })?.action
                else { return }
                self.perform?(action)
            }
            button.attributedTitle =
                segment.parts.map(Self.tinted) ?? Self.title(segment.text, css: segment.css)
            return button
        case .menu:
            let id = segment.id
            let button = BandButton {}
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                let rows = self.facts.segments.first { $0.id == id }?.rows ?? []
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
            button.attributedTitle = Self.title(segment.text, css: segment.css)
            return button
        }
    }
}

/// A quiet text button for the band: no bezel, its meaning re-read from the latest facts at the
/// moment it is clicked — the title under the pointer may be a second newer than the closure
/// that made it.
@MainActor
private final class BandButton: NSButton {
    var onClick: (() -> Void)?

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

    @objc private func fire() {
        onClick?()
    }
}
