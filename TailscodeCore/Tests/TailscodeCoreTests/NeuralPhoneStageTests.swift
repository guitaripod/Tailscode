import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural phone stage")
struct NeuralPhoneStageTests {
    typealias M = NeuralStageMetrics

    private func phone(
        _ width: Double, rows: Int? = nil, scale: Double = 1, density: ChatDensity = .compact
    ) -> M {
        M.make(
            width: width, density: density, input: .touch, rows: rows, phone: true,
            textScale: scale)
    }

    private func steps(_ count: Int, ask: Int? = nil) -> [NeuralStep] {
        (0..<count).map { index in
            NeuralStep(
                id: "s\(index)", index: index, zone: .act,
                status: index == ask ? .waitingApproval : .ok, group: index, messageID: "m",
                title: "Step \(index)")
        }
    }

    private func list(_ count: Int, ask: Int? = nil) -> NeuralStepList {
        NeuralStepList(steps: steps(count, ask: ask))
    }

    @Test("the collapsed card stays 84 and the open stage is a fixed, short, scroll-free column")
    func heights() {
        for width in [320.0, 375, 386, 402, 430, 744] {
            let metrics = phone(width)
            #expect(metrics.isPhone && metrics.arrangement == .accordion)
            #expect(metrics.cardHeight == 84)
            #expect(metrics.stage.height <= 160)
            #expect(metrics.rowsShown == 5 && metrics.listRowHeight == 32)
            #expect(metrics.listHeader.height == 40 && metrics.listRows.height == 160)
            #expect(metrics.footer.height == 36)
            #expect(metrics.rowHeight <= 400)
            #expect(metrics.rowHeight == metrics.footer.maxY)
            #expect(metrics.pinnedRowHeight == metrics.rowHeight)
        }
    }

    @Test("a 402 pt phone opens to 152 + 4 + 40 + 160 + 4 + 36 and never grows with the viewport")
    func fixed() {
        let metrics = phone(386)
        #expect(abs(metrics.stage.height - 208 * M.aspect) < 1e-9)
        #expect(abs(metrics.rowHeight - (208 * M.aspect + 4 + 40 + 160 + 4 + 36)) < 1e-9)
        let tall = M.make(
            width: 386, density: .compact, input: .touch, viewportHeight: 2000, phone: true)
        let short = M.make(
            width: 386, density: .compact, input: .touch, viewportHeight: 320, phone: true)
        #expect(tall == short && tall == metrics)
    }

    @Test("the head is centred, the zone chips and the search are one bar, the list sits under it")
    func regions() {
        let metrics = phone(386)
        #expect(metrics.stage.x == (386 - 208) / 2 && metrics.stage.width == 208)
        #expect(metrics.filterChips == metrics.listHeader)
        #expect(metrics.listHeader.y == metrics.stage.maxY + M.phoneRegionGap)
        #expect(metrics.listRows.y == metrics.listHeader.maxY)
        #expect(metrics.footer.y == metrics.listRows.maxY + M.phoneFooterGap)
        #expect(metrics.listHint == nil && metrics.filterPanel == nil && metrics.readout == .zero)
        #expect(!metrics.hasLeader)
    }

    @Test("a narrow phone shrinks the head to the row and keeps every region inside it")
    func narrow() {
        let metrics = phone(180)
        #expect(metrics.stage.width == 180 && metrics.stage.x == 0)
        for rect in [metrics.stage, metrics.listHeader, metrics.listRows, metrics.footer] {
            #expect(rect.x >= 0 && rect.maxX <= 180)
        }
    }

    @Test("a longer list takes more slots and nothing else changes")
    func expanded() {
        let closed = phone(386)
        let open = phone(386, rows: M.phoneExpandedSlots(visibleCount: 11))
        #expect(open.rowsShown == 12)
        #expect(open.rowHeight - closed.rowHeight == 7 * 32)
        #expect(open.stage == closed.stage && open.listHeader == closed.listHeader)
        #expect(M.phoneExpandedSlots(visibleCount: 2) == 5)
        #expect(M.phoneExpandsInPlace(visibleCount: 12) && !M.phoneExpandsInPlace(visibleCount: 13))
    }

    @Test("larger type grows rows, bar and footer up to one and a half, and smaller never shrinks them")
    func typeScale() {
        let normal = phone(386)
        let large = phone(386, scale: 1.3)
        #expect(large.listRowHeight == 42 && large.listHeader.height == 52)
        #expect(large.footer.height == 47)
        #expect(large.rowHeight > normal.rowHeight)
        #expect(phone(386, scale: 0.8) == normal)
        let huge = phone(386, scale: 3)
        #expect(huge.listRowHeight == 48 && huge == phone(386, scale: 1.5))
        #expect(huge.stage == normal.stage)
    }

    @Test("the move between card and stage reads the phone's own rects")
    func geometry() {
        let metrics = phone(386)
        #expect(metrics.stageGeometry.picture == metrics.stage)
        #expect(metrics.stageGeometry.rowHeight == metrics.rowHeight)
        #expect(metrics.stageGeometry.list == metrics.list)
        #expect(metrics.cardGeometry.rowHeight == 84)
    }

    @Test("the other layouts are exactly what they were: a pointer, a wide touch row and a plain call")
    func unchanged() {
        let plain = M.make(width: 386, density: .compact, input: .touch)
        #expect(!plain.isPhone && plain.stage.width == 280 && plain.rowsShown == 8)
        let pointer = M.make(width: 386, density: .compact, input: .pointer, phone: true)
        #expect(!pointer.isPhone && pointer == M.make(width: 386, density: .compact))
        let wide = M.make(width: 1280, density: .compact, input: .touch, phone: true)
        #expect(!wide.isPhone && wide.arrangement == .split)
        #expect(wide == M.make(width: 1280, density: .compact, input: .touch))
    }

    @Test("a list that fits is shown whole")
    func fits() {
        let window = list(4).compactWindow(slots: 5)
        #expect(window.stepIDs == ["s0", "s1", "s2", "s3"] && !window.hidesSteps)
        #expect(list(5).compactWindow(slots: 5).stepIDs.count == 5)
        #expect(list(0).compactWindow(slots: 5).slots.isEmpty)
    }

    @Test("a long list with no cursor shows its head and says how many more")
    func head() {
        let window = list(29).compactWindow(slots: 5)
        #expect(window.slots == [.step(stepID: "s0"), .step(stepID: "s1"), .step(stepID: "s2"), .step(stepID: "s3"), .more(count: 25)])
        #expect(window.hiddenBefore == 0 && window.hiddenAfter == 25 && window.slots.count == 5)
    }

    @Test("a cursor in the head keeps the head, one in the tail takes the tail")
    func cursorEnds() {
        var near = list(29)
        near.cursor = "s2"
        #expect(near.compactWindow(slots: 5).shown == 0..<4)
        var far = list(29)
        far.cursor = "s27"
        let window = far.compactWindow(slots: 5)
        #expect(window.shown == 25..<29 && window.slots.first == .earlier(count: 25))
        #expect(window.slots.count == 5 && !window.slots.contains { if case .more = $0 { true } else { false } })
    }

    @Test("a cursor in the middle is shown between an earlier row and a more row")
    func cursorMiddle() {
        var middle = list(29)
        middle.cursor = "s14"
        let window = middle.compactWindow(slots: 5)
        #expect(window.slots.count == 5)
        #expect(window.stepIDs.contains("s14"))
        #expect(window.slots.first == .earlier(count: window.hiddenBefore) && window.hiddenBefore > 0)
        #expect(window.slots.last == .more(count: window.hiddenAfter) && window.hiddenAfter > 0)
        #expect(window.hiddenBefore + 3 + window.hiddenAfter == 29)
    }

    @Test("the cursor is on the stage for every position of every list length")
    func cursorAlwaysShown() {
        for count in [6, 7, 12, 29, 60] {
            for slots in [3, 5, 8] {
                for position in 0..<count {
                    var items = list(count)
                    items.cursor = "s\(position)"
                    let window = items.compactWindow(slots: slots)
                    #expect(window.stepIDs.contains("s\(position)"), "count \(count) slots \(slots) cursor \(position)")
                    #expect(window.slots.count <= max(slots, 3))
                    #expect(window.shown.lowerBound >= 0 && window.shown.upperBound <= count)
                }
            }
        }
    }

    @Test("a running list that follows shows its newest steps under an earlier row")
    func following() {
        var running = NeuralStepList(steps: steps(29), live: true)
        #expect(running.isFollowing)
        let window = running.compactWindow(slots: 5)
        #expect(window.slots == [.earlier(count: 25), .step(stepID: "s25"), .step(stepID: "s26"), .step(stepID: "s27"), .step(stepID: "s28")])
        running.following = false
        running.cursor = "s3"
        #expect(running.compactWindow(slots: 5).shown == 0..<4)
    }

    @Test("a step waiting on the person takes the first slot and leaves the rest one fewer")
    func asking() {
        let waiting = list(29, ask: 28)
        let window = waiting.compactWindow(slots: 5)
        #expect(window.slots.first == .ask(stepID: "s28"))
        #expect(window.slots.count == 5)
        #expect(window.stepIDs.count == 3)
        #expect(list(3, ask: 1).compactWindow(slots: 5).slots.count == 4)
    }

    @Test("a filter narrows the window to the rows that pass")
    func filtered() {
        var items = list(29)
        items.setSearch("Step 2")
        let window = items.compactWindow(slots: 5)
        #expect(items.visibleCount == 10)
        #expect(window.total == 10 && window.stepIDs.count == 4)
    }
}
