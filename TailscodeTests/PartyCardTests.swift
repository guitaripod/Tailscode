import CodingAgentKit
import Foundation
import Testing
import TailscodeCore
import UIKit

@testable import Tailscode

/// A card is one control, and a press anywhere on it has to arrive as the card's own: a label, a
/// stack or a pill under the finger must never be the view a press begins on. In Edit the model's
/// line is a button of its own, and only the three real controls inside a card keep their touches.
@MainActor
struct PartyCardTests {
    private func card(editing: Bool, server: Bool = true) -> PartyCardView {
        let model = ModelInfo(
            id: "claude-opus-5", name: "Claude Opus 5", providerID: "anthropic",
            variants: ["low", "high"])
        let source = ModelSource(
            profileID: "arch", name: "Arch", backend: .claudeCode, models: [model], isCurrent: true,
            allowsServerDefault: true, acceptsAnyModelID: true, isReachable: true)
        let slots: [PartySlot?] = [
            PartySlot(
                preset: ModelPreset(selection: model.selection, effort: .level("high")), name: "Daily"),
            nil, nil, nil, nil, nil,
        ]
        let reading = PartyReading.cards(
            slots: slots, sources: [source], model: nil, effort: nil, agentOptions: [])[0]
        let view = PartyCardView(slot: 0)
        view.frame = CGRect(x: 0, y: 0, width: 170, height: 150)
        view.render(reading, editing: editing, busy: false)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    private func points(in bounds: CGRect) -> [CGPoint] {
        stride(from: bounds.minX + 6, to: bounds.maxX - 6, by: 14).flatMap { x in
            stride(from: bounds.minY + 6, to: bounds.maxY - 6, by: 14).map { CGPoint(x: x, y: $0) }
        }
    }

    @Test func everyPointOnABrowsingCardIsTheCardItself() {
        let view = card(editing: false)
        for point in points(in: view.bounds) {
            #expect(view.hitTest(point, with: nil) === view, "at \(point)")
        }
    }

    @Test func aBrowsingCardTakesAPressAnywhereOnIt() {
        let view = card(editing: false)
        var taken = 0
        view.onTake = { taken += 1 }
        view.onReplace = { Issue.record("replace is Edit's") }
        view.press(at: view.modelLineCenter)
        view.press(at: nil)
        #expect(taken == 2)
    }

    @Test func inEditThePressOnTheModelLineReplacesAndNothingElseDoes() {
        let view = card(editing: true)
        var replaced = 0
        view.onTake = { Issue.record("a card in Edit is not taken") }
        view.onReplace = { replaced += 1 }
        view.press(at: view.modelLineCenter)
        view.press(at: CGPoint(x: 4, y: 4))
        view.press(at: nil)
        #expect(replaced == 1)
    }

    @Test func inEditTheNameTheStepperAndTheBadgeKeepTheirOwnTouches() {
        let view = card(editing: true)
        let hits = points(in: view.bounds).compactMap { view.hitTest($0, with: nil) }
        #expect(hits.contains { $0 is UITextView })
        #expect(hits.contains { $0 is UIButton })
        #expect(hits.contains { $0 === view })
        #expect(!hits.contains { $0 is UILabel || $0 is UIStackView })
    }
}
