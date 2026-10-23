import AppKit
import TailscodeCore

extension BrainCardView {
    func target(at point: CGPoint) -> CardTarget? {
        layout.targets.last { $0.rect.contains(point) && ($0.kind != .replay || content?.canReplay == true) }
    }

    func setHovered(_ value: Bool, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = value ? target(at: point)?.kind : nil
        let changed = value != hovered || next != hoverTarget
        hovered = value
        hoverTarget = next
        guard changed else { return }
        if value != hovered || true { onHover?(value) }
        needsDisplay = true
        if value { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        refreshLightsHover()
    }

    private func refreshLightsHover() { onLightsHover?(hovered) }

    func invalidateAccessibility() {
        guard let content else { return }
        elements = []
        func element(
            _ label: String, _ rect: CGRect, help: String? = nil, _ press: @escaping @MainActor () -> Void
        ) {
            let item = BrainPressElement()
            item.setAccessibilityRole(.button)
            item.setAccessibilityLabel(label)
            item.setAccessibilityHelp(help)
            item.setAccessibilityParent(self)
            item.setAccessibilityFrameInParentSpace(rect)
            item.onPress = press
            elements.append(item)
        }
        for target in layout.targets {
            switch target.kind {
            case .replay: element(NeuralReading.replayLabel, target.rect) { [weak self] in self?.onReplay?() }
            case .rows:
                element(
                    NeuralReading.rowsLabel, target.rect,
                    help: NeuralReading.rowsHelp(showingRows: content.showsRows)
                ) { [weak self] in self?.onRows?() }
            case .open: element(Localized.text("Open"), target.rect) { [weak self] in self?.onOpen?() }
            case .zone(let zone):
                element(zone.displayLabel, target.rect) { [weak self] in self?.onZone?(zone) }
            }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(NeuralReading.named(content.card.spoken))
    }

    /// What the harness reads: how many chips and buttons the layout holds and what it drew.
    var reading: (chips: Int, buttons: Int, headline: String, hasLive: Bool) {
        (
            layout.chipRects.count, layout.targets.filter { if case .zone = $0.kind { return false } else { return true } }.count,
            content?.card.headline.pieces.map(\.text).joined(separator: " ") ?? "", liveCard != nil
        )
    }

    var chipCenters: [(zone: NeuralZone, point: CGPoint)] {
        layout.chipRects.map { ($0.chip.zone, CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
    }
}
