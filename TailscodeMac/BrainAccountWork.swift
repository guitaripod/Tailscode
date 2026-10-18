import AppKit
import CodingAgentKit
import TailscodeCore

/// The one line a run of work is folded to: the zone marks of what ran, the work as clauses in the
/// reader's words each wearing its verdict where it has one, the errors fixed in amber and the ones
/// that stayed in red, and the steps' numbers as a chip at the right. A press folds or unfolds it.
@MainActor
final class AccountWorkLine: NSView {
    private let work: AccountEntry.Work
    private let open: Bool
    private let paint: AccountPaint
    let chip: AccountButton
    var onToggle: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var clauseWords: [String]

    init(work: AccountEntry.Work, open: Bool, paint: AccountPaint, host: BrainSurfaceHost?, chipTarget: (() -> Void)?) {
        self.work = work
        self.open = open
        self.paint = paint
        clauseWords = work.clauses.map(\.text)
        chip = AccountButton(title: AccountWords.stepRange(work.numbers), style: .step, paint: paint)
        super.init(frame: .zero)
        chip.host = host
        chip.onTap = chipTarget
        chip.setAccessibilityLabel(Localized.text("Step %@", AccountWords.stepRange(work.numbers)))
        addSubview(chip)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(work.clauses.map(\.text).joined(separator: ", "))
        setAccessibilityExpanded(open)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    var words: [String] { clauseWords }

    func fit(width: CGFloat) -> CGFloat {
        setFrameSize(NSSize(width: width, height: 36))
        let size = chip.fittingSize
        chip.frame = CGRect(x: width - 12 - size.width, y: (36 - size.height) / 2, width: size.width, height: size.height)
        needsDisplay = true
        return 36
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    /// Whether a clause is a build, a test run or a lint that passed: the one kind of clause that
    /// wears a check, because those are the ones a result is judged by.
    private func isPassedCheck(_ clause: AccountEntry.Clause) -> Bool {
        guard clause.verdict == .done else { return false }
        return NeuralHuman.CheckKind.allCases.contains { $0.title == clause.text || $0.againTitle == clause.text }
    }

    private func clauseMark(_ clause: AccountEntry.Clause) -> NeuralVerdict.Step? {
        if isPassedCheck(clause) { return .done }
        return clause.verdict.isMarked ? clause.verdict : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 8
        NSGraphicsContext.saveGraphicsState()
        if open { bounds.clip() }
        let shape = NSBezierPath(
            roundedRect: open ? NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + radius) : rect,
            xRadius: radius, yRadius: radius)
        paint.raised.setFill()
        shape.fill()
        (open || hovered ? paint.rule2 : paint.rule).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if open {
            (paint.rule2).setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }

        let mid = bounds.midY
        var x: CGFloat = 10
        AccountType.draw(open ? "\u{25BE}" : "\u{25B8}", .rowStamp, paint.dim, x: x, midY: mid)
        x += 10 + 14
        for zone in work.zones {
            AccountGlyphs.zone(zone, cx: x + 9, cy: mid, color: paint.zone(zone))
            x += 22
        }
        x += -4 + 14
        let chipWidth = chip.frame.width
        let rightEdge = bounds.width - 12 - chipWidth - 14
        var room = rightEdge - x
        var summaries: [(words: String, verdict: NeuralVerdict.Step)] = []
        if work.fixedCount > 0 {
            let words = work.fixedCount == 1
                ? (work.fixedWords.first ?? AccountWords.fixedErrors(1)) : AccountWords.fixedErrors(work.fixedCount)
            summaries.append((words, .fixed))
        }
        if work.unfixedCount > 0 { summaries.append((AccountWords.failedCount(work.unfixedCount), .failed)) }
        summaries = summaries.filter { item in
            let whole = 14 + 6 + AccountType.width(item.words, .control) + 14
            guard whole <= room * 0.5 else { return false }
            room -= whole
            return true
        }
        var taken = 0
        var used: CGFloat = 0
        let moreReserve = AccountType.width(AccountWords.moreClauses(99), .control) + 14
        let start = x
        for clause in work.clauses {
            let mark = clauseMark(clause)
            let textWidth = AccountType.width(clause.text, .control)
            let width = textWidth + (mark == nil ? 0 : 6 + 14) + (taken == 0 ? 0 : 14)
            let remaining = work.clauses.count - taken - 1 + work.more
            let reserve = remaining > 0 ? moreReserve : 0
            if used + width + reserve > room, taken > 0 { break }
            if taken > 0 {
                AccountType.draw("\u{00B7}", .control, paint.dim, x: x + 7 - 2, midY: mid)
                x += 14
            }
            let room2 = max(room - used - (taken == 0 ? 0 : 14) - (mark == nil ? 0 : 20) - reserve, 20)
            let drawn = AccountType.draw(clause.text, .control, paint.text, x: x, midY: mid, maxWidth: min(textWidth + 1, room2))
            x += drawn
            if let mark {
                AccountGlyphs.verdict(mark, cx: x + 6 + 7, cy: mid, size: 14, color: paint.verdict(mark))
                x += 6 + 14
            }
            used = x - start
            taken += 1
        }
        let hidden = work.clauses.count - taken + work.more
        if hidden > 0 {
            AccountType.draw("\u{00B7}", .control, paint.dim, x: x + 7 - 2, midY: mid)
            x += 14
            x += AccountType.draw(AccountWords.moreClauses(hidden), .control, paint.dim, x: x, midY: mid)
        }
        for item in summaries where !item.words.isEmpty {
            x += 14
            let color = paint.verdict(item.verdict)
            AccountGlyphs.verdict(item.verdict, cx: x + 7, cy: mid, size: 14, color: color)
            x += 14 + 6
            x += AccountType.draw(
                item.words, .control, item.verdict == .failed ? paint.danger : paint.warn, x: x, midY: mid,
                maxWidth: max(rightEdge - x, 20))
        }
    }
}


/// A run of the step list's own rows, drawn into the account: the same pixels the list beside
/// the head paints, for the steps of a work line that is unfolded. It owns the pointer's row and the
/// Copy button of the row under it, and nothing else; a press is the list's press.
@MainActor
final class AccountRowsView: NSView {
    unowned let owner: BrainAccountView
    let ids: [String]
    let before: String?
    let after: String?
    private var hoverID: String?
    private var hoverCopy = false
    private var copied: (id: String, until: Double)?
    private var tracking: NSTrackingArea?
    private let input: ChatInput

    init(owner: BrainAccountView, ids: [String], before: String?, after: String?) {
        self.owner = owner
        self.ids = ids
        self.before = before
        self.after = after
        input = owner.metrics.input
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(AccountWords.steps(ids.count))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }

    private var list: NeuralStepList { owner.model.browseState.list }

    private func row(_ id: String) -> NeuralStepList.Row? { list.row(id: id) }

    private func height(of id: String) -> CGFloat {
        CGFloat(row(id)?.height(input: input) ?? NeuralStageMetrics.listRowHeight(input: input))
    }

    var totalHeight: CGFloat { ids.reduce(0) { $0 + height(of: $1) } }

    private func rowIndex(atY y: CGFloat) -> Int? {
        var top: CGFloat = 0
        for (index, id) in ids.enumerated() {
            let h = height(of: id)
            if y >= top, y < top + h { return index }
            top += h
        }
        return nil
    }

    private func top(of index: Int) -> CGFloat { ids.prefix(index).reduce(0) { $0 + height(of: $1) } }

    func flashCopied(_ id: String) {
        copied = (id, CACurrentMediaTime() + 1)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in self?.needsDisplay = true }
    }

    private func copyRect(for row: NeuralStepList.Row, width: CGFloat) -> CGRect {
        let label = copied?.id == row.id && (copied?.until ?? 0) > CACurrentMediaTime() ? AccountWords.copied : NeuralReading.copyLabel
        let size = AccountType.width(label, .rowMeta) + 18
        return CGRect(x: width - 6 - size, y: (CGFloat(row.height(input: input)) - 24) / 2, width: size, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(atY: point.y), let found = row(ids[index]) else {
            mouseExited(with: event)
            return
        }
        let id = ids[index]
        let rect = copyRect(for: found, width: bounds.width)
        let local = CGPoint(x: point.x, y: point.y - top(of: index))
        let onCopy = rect.contains(local)
        if hoverID != id || hoverCopy != onCopy {
            hoverID = id
            hoverCopy = onCopy
            needsDisplay = true
            owner.hover(id)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverID != nil else { return }
        hoverID = nil
        hoverCopy = false
        needsDisplay = true
        owner.hover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(atY: point.y), let found = row(ids[index]) else { return }
        let id = ids[index]
        let rect = copyRect(for: found, width: bounds.width)
        if hoverID == id, rect.contains(CGPoint(x: point.x, y: point.y - top(of: index))) {
            owner.copyItem(id)
            flashCopied(id)
            return
        }
        owner.choose(id, fromAccount: true, double: event.clickCount >= 2)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(atY: point.y) else { return }
        owner.host?.presentMenu(forStep: ids[index], event: event, in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let paint = owner.paint
        let model = owner.model
        let cursor = model.pinnedStep
        let hovered = model.browseState.hovered
        let query = list.filter.query
        var y: CGFloat = 0
        for (index, id) in ids.enumerated() {
            guard let found = row(id) else { continue }
            let h = CGFloat(found.height(input: input))
            defer { y += h }
            if y + h < dirtyRect.minY - 1 { continue }
            if y > dirtyRect.maxY + 1 { break }
            let previous = index > 0 ? row(ids[index - 1]) : before.flatMap { row($0) }
            let next = index + 1 < ids.count ? row(ids[index + 1]) : after.flatMap { row($0) }
            paintRow(
                found, previous: previous, next: next, y: y, height: h, width: bounds.width, paint: paint,
                isCursor: cursor == id, isHovered: hovered == id && cursor != id, pointerHere: hoverID == id,
                query: query)
        }
    }

    private func paintRow(
        _ row: NeuralStepList.Row, previous: NeuralStepList.Row?, next: NeuralStepList.Row?, y: CGFloat,
        height rowH: CGFloat, width: CGFloat, paint: AccountPaint, isCursor: Bool, isHovered: Bool,
        pointerHere: Bool, query: String
    ) {
        let zone = paint.zone(row.zone)
        if row.status == .failed {
            paint.danger.withAlphaComponent(0.08).setFill()
            NSRect(x: 0, y: y, width: width, height: rowH).fill()
        }
        if isCursor {
            paint.accent.withAlphaComponent(0.14).setFill()
            NSRect(x: 0, y: y, width: width, height: rowH).fill()
        } else if isHovered {
            paint.text.withAlphaComponent(0.06).setFill()
            NSRect(x: 0, y: y, width: width, height: rowH).fill()
        }
        zone.setFill()
        NSRect(x: 0, y: y, width: 3, height: rowH).fill()
        if isCursor {
            paint.accent.setFill()
            NSRect(x: 3, y: y, width: 2, height: rowH).fill()
            paint.accent.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(roundedRect: NSRect(x: 0.5, y: y + 0.5, width: width - 1, height: rowH - 1), xRadius: 2, yRadius: 2)
            ring.lineWidth = 1
            ring.stroke()
        }
        paintBracket(row, previous: previous, next: next, y: y, height: rowH, paint: paint)
        let said = row.isSaid
        let band: CGFloat = said ? 28 : rowH
        let mid = y + band / 2
        if said {
            AccountGlyphs.quote(cx: 34, cy: y + 14, color: paint.accent)
        } else {
            AccountGlyphs.zone(row.zone, cx: 34, cy: mid, color: zone)
        }
        AccountType.draw("\(row.number)", .rowMeta, paint.dim, x: 75, midY: mid, maxWidth: 24, rightAligned: true)
        let statusLeft = paintStatus(row, y: y, height: rowH, width: width, paint: paint, showCopy: pointerHere || copiedNow(row.id))
        let limit = statusLeft - 12
        if row.kind == .tool {
            let titleWidth = min(AccountType.width(row.title, .rowTitleStrong), 168)
            AccountType.draw(row.title, .rowTitleStrong, paint.text, x: 83, midY: mid, maxWidth: titleWidth)
            let argumentX = 83 + titleWidth + 10
            let room = max(0, limit - argumentX)
            let chars = max(0, Int(room / AccountType.monoWidth(.rowDetail)))
            let shown = row.argument(fittingChars: chars)
            if !query.isEmpty, let range = shown.range(of: query, options: .caseInsensitive) {
                let startChars = shown.distance(from: shown.startIndex, to: range.lowerBound)
                let length = shown.distance(from: range.lowerBound, to: range.upperBound)
                let monoWidth = AccountType.monoWidth(.rowDetail)
                paint.warn.withAlphaComponent(0.34).setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: argumentX + CGFloat(startChars) * monoWidth - 1, y: y + 5, width: CGFloat(length) * monoWidth + 2,
                        height: rowH - 10), xRadius: 3, yRadius: 3
                ).fill()
            }
            AccountType.draw(shown, .rowDetail, paint.dim, x: argumentX, midY: mid, maxWidth: room)
        } else if said {
            let room = max(0, limit - 83)
            let text = AccountType.string(row.lines.joined(separator: " "), .thought, paint.text)
            text.draw(
                with: NSRect(x: 83, y: y + 4, width: room, height: 32),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        } else {
            AccountType.draw(row.argument, .thought, paint.dim, x: 83, midY: mid, maxWidth: max(0, limit - 83))
        }
    }

    private func copiedNow(_ id: String) -> Bool {
        guard let copied else { return false }
        return copied.id == id && copied.until > CACurrentMediaTime()
    }

    private func paintBracket(
        _ row: NeuralStepList.Row, previous: NeuralStepList.Row?, next: NeuralStepList.Row?, y: CGFloat,
        height rowH: CGFloat, paint: AccountPaint
    ) {
        guard row.bracket != .none else { return }
        let joinsAbove = previous.map { $0.group == row.group && $0.bracket != .none } ?? false
        let joinsBelow = next.map { $0.group == row.group && $0.bracket != .none } ?? false
        guard joinsAbove || joinsBelow else { return }
        let mid = y + rowH / 2
        paint.dim.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 9.5, y: joinsAbove ? y : mid))
        path.line(to: NSPoint(x: 9.5, y: joinsBelow ? y + rowH : mid))
        path.move(to: NSPoint(x: 9.5, y: mid))
        path.line(to: NSPoint(x: 15.5, y: mid))
        path.lineWidth = 1
        path.stroke()
    }

    /// The mark on the right of a row and the left edge it begins at; the copy button of a hovered
    /// row stands in its place.
    private func paintStatus(
        _ row: NeuralStepList.Row, y: CGFloat, height rowH: CGFloat, width: CGFloat, paint: AccountPaint,
        showCopy: Bool
    ) -> CGFloat {
        let band: CGFloat = row.isSaid ? 28 : rowH
        let mid = y + band / 2
        if showCopy {
            let rect = copyRect(for: row, width: width)
            let label = copiedNow(row.id) ? AccountWords.copied : NeuralReading.copyLabel
            let shape = NSBezierPath(
                roundedRect: NSRect(x: rect.minX + 0.5, y: y + rect.minY + 0.5, width: rect.width - 1, height: rect.height - 1),
                xRadius: 12, yRadius: 12)
            paint.raised.setFill()
            shape.fill()
            (hoverCopy && hoverID == row.id ? paint.accent : paint.rule2).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            AccountType.draw(label, .rowMeta, paint.text, x: rect.midX - AccountType.width(label, .rowMeta) / 2, midY: y + rect.midY)
            return rect.minX
        }
        let right = width - 10
        let verdict = row.verdict
        guard verdict.isMarked else { return right }
        let color = paint.verdict(verdict)
        switch verdict {
        case .fixed:
            let target = row.related.map { "\u{2192}\($0.number)" } ?? ""
            let size = AccountType.width(target, .rowMeta)
            if !target.isEmpty { AccountType.draw(target, .rowMeta, color, x: right - size, midY: mid) }
            let glyphX = right - size - (target.isEmpty ? 0 : 6) - 7
            AccountGlyphs.verdict(.fixed, cx: glyphX, cy: mid, size: 13, color: color)
            return glyphX - 12
        default:
            AccountGlyphs.verdict(verdict, cx: right - 6, cy: mid, size: 13, color: color)
            return right - 20
        }
    }
}


@MainActor
final class AccountWorkCell: AccountCell {
    struct CardSpec: Equatable {
        let id: String
        let preview: Bool
        let live: Bool
    }

    private struct Chunk {
        let y: CGFloat
        let height: CGFloat
        let ids: [String]
        let before: String?
        let after: String?
        var view: AccountRowsView?
    }

    private let entry: AccountEntry
    private let work: AccountEntry.Work
    private let open: Bool
    private let cards: [CardSpec]
    private let line: AccountWorkLine
    private var chunks: [Chunk] = []
    private var pages: [(spec: CardSpec, page: AccountReadoutPage)] = []
    private var moreLink: AccountButton?
    private var moreNote = ""
    private var rowsFrame = CGRect.zero
    private(set) var cursorPage: AccountReadoutPage?
    private static let chunkRows = 24

    init(entry: AccountEntry, work: AccountEntry.Work, key: String, owner: BrainAccountView) {
        self.entry = entry
        self.work = work
        open = owner.isOpen(entry, work: work)
        cards = owner.cardSteps(for: entry, work: work)
        let target = work.chipStepID ?? work.firstStepID
        line = AccountWorkLine(
            work: work, open: open, paint: owner.paint, host: owner.host,
            chipTarget: { [weak owner] in if let target { owner?.choose(target, fromAccount: true) } })
        super.init(entryID: entry.id, key: key, owner: owner)
        line.onToggle = { [weak owner, id = entry.id] in owner?.toggleWork(id) }
        addSubview(line)
    }

    override var drawnWords: [String] { line.words + (moreNote.isEmpty ? [] : [moreNote]) }

    func toggleCursorCardOutput() -> Bool {
        guard let page = cursorPage else { return false }
        return page.toggleOutput()
    }

    /// A card the open row has under it: what the readout used to say about the step, in place.
    private func makeCard(_ spec: CardSpec) -> AccountReadoutPage {
        let model = owner.model
        let page = AccountReadoutPage(owner: owner, mode: .card)
        page.isPreview = spec.preview
        page.isLive = spec.live
        let lines = owner.metrics.outputLinesShown
        if spec.live {
            let value = NeuralReadout.make(
                model: model, subject: .now, now: Date(), tz: .current, clock: CACurrentMediaTime(), answer: nil,
                outputLines: lines)
            if case .now(let now) = value.body, let running = now.step {
                page.showLive(running, tail: now.tail)
            }
        } else {
            let value = NeuralReadout.make(
                model: model, subject: .step(spec.id), now: Date(), tz: .current, clock: CACurrentMediaTime(),
                answer: nil, outputLines: lines)
            page.show(value, paint: owner.paint, animate: false)
        }
        page.onHeight = { [weak self] in
            guard let self else { return }
            self.owner.cellHeightChanged(self)
        }
        return page
    }

    override func fit(width: CGFloat) -> CGFloat {
        let previous = pages
        pages = []
        cursorPage = nil
        for chunk in chunks { chunk.view?.removeFromSuperview() }
        chunks = []
        moreLink?.removeFromSuperview()
        moreLink = nil
        moreNote = ""
        reusable = previous
        var y = line.fit(width: width)
        line.frame = CGRect(x: 0, y: 0, width: width, height: 36)
        if open {
            let rowsTop = y
            y += 4
            let ids = work.stepIDs
            let cap = ids.count
            var shownCount = min(cap, owner.rowCap(entryID))
            for spec in cards {
                if let at = ids.firstIndex(of: spec.id) { shownCount = max(shownCount, min(cap, at + 1)) }
            }
            let shown = Array(ids.prefix(shownCount))
            let ordered = cards.compactMap { spec in shown.firstIndex(of: spec.id).map { ($0, spec) } }.sorted { $0.0 < $1.0 }
            var start = 0
            func segment(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                var from = range.lowerBound
                while from < range.upperBound {
                    let to = min(from + Self.chunkRows, range.upperBound)
                    let part = Array(shown[from..<to])
                    let before = from > 0 ? shown[from - 1] : nil
                    let after = to < shown.count ? shown[to] : nil
                    let probe = AccountRowsView(owner: owner, ids: part, before: before, after: after)
                    let height = probe.totalHeight
                    chunks.append(Chunk(y: y, height: height, ids: part, before: before, after: after, view: nil))
                    y += height
                    from = to
                }
            }
            for (index, spec) in ordered {
                segment(start..<(index + 1))
                y = addCard(spec, y: y, width: width)
                start = index + 1
            }
            segment(start..<shown.count)
            if shownCount < ids.count {
                let remaining = ids.count - shownCount
                y += 6
                if shownCount >= BrainAccountView.rowMax {
                    moreNote = Localized.text("%lld more steps are in the list", remaining)
                    let top = y
                    moreNoteY = top + 8
                    y += 18
                } else {
                    let made = linkButton(AccountWords.moreSteps(min(remaining, BrainAccountView.rowStride))) {
                        [weak owner, id = entryID] in owner?.moreRows(id)
                    }
                    let size = made.fittingSize
                    made.frame = CGRect(x: 14, y: y, width: size.width, height: size.height)
                    addSubview(made)
                    moreLink = made
                    y += size.height
                }
                y += 4
            }
            y += 4
            rowsFrame = CGRect(x: 0, y: rowsTop, width: width, height: y - rowsTop)
        } else {
            rowsFrame = .zero
            for spec in cards { y = addCard(spec, y: y, width: width) }
        }
        for entry in previous where !pages.contains(where: { $0.page === entry.page }) {
            entry.page.removeFromSuperview()
        }
        reusable = []
        setFrameSize(NSSize(width: width, height: y))
        realizeChunks(visible: owner.documentVisible)
        needsDisplay = true
        return y
    }

    private var moreNoteY: CGFloat = 0
    private var reusable: [(spec: CardSpec, page: AccountReadoutPage)] = []

    private func addCard(_ spec: CardSpec, y: CGFloat, width: CGFloat) -> CGFloat {
        let page = reusable.first { $0.spec == spec }?.page ?? makeCard(spec)
        let cardWidth = max(width - 36 - 12, 80)
        let height = page.fitCard(width: cardWidth)
        page.frame = CGRect(x: 36, y: y + 4, width: cardWidth, height: height)
        if page.superview !== self { addSubview(page) }
        pages.append((spec, page))
        if !spec.preview { cursorPage = page }
        return y + 4 + height + 8
    }

    override func visibleChanged(_ rect: CGRect) {
        realizeChunks(visible: rect)
    }

    /// The row canvases that are near the reader exist; the others are not made, so a work line of
    /// four hundred rows costs what the rows on screen cost.
    private func realizeChunks(visible: CGRect) {
        guard !chunks.isEmpty else { return }
        let top = owner.entryIndex[entryID].flatMap { index in
            index < owner.offsets.count ? owner.offsets[index] : nil
        } ?? frame.minY
        let near = CGRect(x: 0, y: visible.minY - top - 300, width: bounds.width, height: visible.height + 600)
        for index in chunks.indices {
            let chunk = chunks[index]
            let wanted = CGRect(x: 0, y: chunk.y, width: bounds.width, height: chunk.height).intersects(near)
            if wanted, chunk.view == nil {
                let view = AccountRowsView(owner: owner, ids: chunk.ids, before: chunk.before, after: chunk.after)
                view.frame = CGRect(x: 0, y: chunk.y, width: bounds.width, height: chunk.height)
                addSubview(view, positioned: .below, relativeTo: nil)
                chunks[index].view = view
            } else if !wanted, let view = chunk.view {
                view.removeFromSuperview()
                chunks[index].view = nil
            }
        }
    }

    func flashCopied(_ stepID: String) {
        for chunk in chunks { chunk.view?.flashCopied(stepID) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rowsFrame.isEmpty else { return }
        let paint = paint
        let rect = rowsFrame.insetBy(dx: 0.5, dy: 0)
        NSGraphicsContext.saveGraphicsState()
        rowsFrame.clip()
        let shape = NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY - 8, width: rect.width, height: rect.height + 8 - 0.5),
            xRadius: 8, yRadius: 8)
        paint.raised.withAlphaComponent(0.6).setFill()
        shape.fill()
        paint.rule2.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if !moreNote.isEmpty {
            AccountType.draw(moreNote, .rowStamp, paint.dim, x: 14, midY: moreNoteY + 2)
        }
    }

    override func teardown() {
        for chunk in chunks { chunk.view?.removeFromSuperview() }
        chunks = []
        pages = []
        cursorPage = nil
    }
}


extension BrainAccountView {
    func cellKey(_ entry: AccountEntry) -> String {
        let cursor = model.pinnedStep
        let stamp = "\(Int(boxWidth))|\(paint.inks.palette.name)|\(host?.density == .compact ? "c" : "n")"
        switch entry.kind {
        case .said(let said):
            return "s|\(said.id)|\(said.text.utf8.count)|\(said.showsSpeaker)|\(cursor == said.stepID)|\(expandedText.contains(entry.id))|\(stamp)|\(justNow[entry.id] != nil)"
        case .thought(let thought):
            return "t|\(thought.id)|\(thought.text.utf8.count)|\(cursor == thought.stepID)|\(expandedText.contains(entry.id))|\(stamp)"
        case .work(let work):
            let marked = workStamps[entry.id] ?? 0
            let cards = cardSteps(for: entry, work: work)
            let open = isOpen(entry, work: work)
            let cardKey = cards.map { "\($0.id)\($0.live)\($0.preview)" }.joined(separator: ",")
            return "w|\(entry.id)|\(marked)|\(open)|\(cardKey)|\(rowCap(entry.id))|\(cursor ?? "-")|\(stamp)|\(work.clauses.map(\.text).joined(separator: "/"))"
        case .asked(let asked):
            return "q|\(asked.id)|\(asked.text.utf8.count)|\(expandedText.contains(entry.id))|\(stamp)"
        case .plan(let plan):
            let open = planStoryOpen(entry, plan)
            return "p|\(entry.id)|\(plan.items.map { "\($0.text)\($0.state)" }.joined(separator: "|"))|\(open)|\(stamp)"
        case .result(let result):
            return "r|\(entry.id)|\(result.checks.map { "\($0.command)\($0.verdict)\($0.retries)" }.joined(separator: "|"))|\(result.changes.map { "\($0.path)\($0.added)\($0.removed)" }.joined(separator: "|"))|\(result.unfixed.count)|\(result.answer ?? "")|\(stamp)"
        }
    }

    /// The steps of a work line whose card is open under them: the cursor's, the hovered one's as a
    /// preview beside it when the hover came from outside the account, and the step a running
    /// turn is on while the account follows it.
    func cardSteps(for entry: AccountEntry, work: AccountEntry.Work) -> [AccountWorkCell.CardSpec] {
        let m = metrics
        guard m.accountLayout == .single || m.arrangement == .accordion else { return [] }
        var out: [AccountWorkCell.CardSpec] = []
        let model = model
        let cursor = model.pinnedStep
        if let cursor, work.stepIDs.contains(cursor) {
            out.append(.init(id: cursor, preview: false, live: isRunningStep(cursor)))
        }
        if let hovered = model.browseState.hovered, hovered != cursor, hovered != localHover,
            work.stepIDs.contains(hovered)
        {
            out.append(.init(id: hovered, preview: true, live: false))
        }
        if out.isEmpty, liveTip(work: work), let last = work.stepIDs.last, isRunningStep(last) {
            out.append(.init(id: last, preview: false, live: true))
        }
        return out
    }

    private func isRunningStep(_ id: String) -> Bool {
        guard let step = model.step(id: id) else { return false }
        return model.turn.outcome == .running && step.status == .running
    }

    func buildCell(_ entry: AccountEntry, key: String) -> AccountCell {
        switch entry.kind {
        case .said(let said): return AccountSaidCell(entry: entry, said: said, key: key, owner: self)
        case .thought(let thought): return AccountThoughtCell(entry: entry, thought: thought, key: key, owner: self)
        case .work(let work): return AccountWorkCell(entry: entry, work: work, key: key, owner: self)
        case .asked(let asked): return AccountAskedCell(entry: entry, asked: asked, key: key, owner: self)
        case .plan(let plan): return AccountPlanCell(entry: entry, plan: plan, key: key, owner: self)
        case .result(let result): return AccountResultCell(entry: entry, result: result, key: key, owner: self)
        }
    }
}
