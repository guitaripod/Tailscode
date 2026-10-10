import AppKit
import TailscodeCore

extension TranscriptRow {
    var spacing: ChatRowSpacing { ChatLayout.spacing(of: kind) }
}

/// What a transcript row is for the purpose of the space around it: one of Core's classes, or the
/// seam between two turns, which is not a row anybody reads but the air a new question is given.
enum ChatRowSpacing: Hashable {
    case row(ChatRowClass)
    case turnBreak
}

/// The Mac's mapping of Core's chat table onto its own rows, in one place so a row kind is never
/// given its air anywhere else.
enum ChatLayout {
    /// The numbers the open transcript is laid out with: the reader's density, read for a pointer.
    static var metrics: ChatMetrics {
        ChatMetrics.metrics(for: ChatDensitySetting.current, input: .pointer)
    }

    /// The class a row kind is spaced as. Block-weight rows that are not prose or code — cards,
    /// boards, a failure's statement — are spaced as prose, because they are something to read and
    /// not a line to glance past; only the one-line furniture sits close to its neighbours.
    static func spacing(of kind: TranscriptRow.Kind) -> ChatRowSpacing {
        switch kind {
        case .userText, .pendingSend, .queuedSend:
            return .row(.prompt)
        case .file(_, let mine, _):
            return .row(mine ? .prompt : .picture)
        case .agentProse, .table, .tableDraft, .subagent, .workflow, .designBoard, .taskBoard,
            .answerless, .interruptedTurn, .providerRetry, .revertBanner:
            return .row(.prose)
        case .codeBlock:
            return .row(.code)
        case .linkRail:
            return .row(.rail)
        case .compaction:
            return .row(.seam)
        case .interruption, .reasoning, .tool, .run, .responseStats, .note, .revertPending:
            return .row(.furniture)
        case .turnBreak:
            return .turnBreak
        }
    }

    /// The air between two neighbouring rows. A turn break stands for the turn gap, half of it on
    /// either side of its hairline, so the space between turns is the table's number whether or not
    /// the rule is drawn.
    static func gap(from previous: ChatRowSpacing?, to next: ChatRowSpacing, metrics: ChatMetrics)
        -> CGFloat
    {
        guard let previous else { return 0 }
        switch (previous, next) {
        case (.turnBreak, _), (_, .turnBreak):
            return CGFloat(metrics.turnGap / 2)
        case (.row(let above), .row(let below)):
            return CGFloat(metrics.gap(from: above, to: below))
        }
    }
}

/// The line of pictures being filled: where it began, how far along it has got, and how tall its
/// tallest picture is, which is what the next line starts under.
struct PictureLine: Equatable {
    var top: CGFloat = 0
    var cursor: CGFloat = 0
    var height: CGFloat = 0

    func accepts(_ width: CGFloat, in available: CGFloat) -> Bool {
        cursor + width <= available
    }

    mutating func take(width: CGFloat, height rowHeight: CGFloat, gap: CGFloat) {
        cursor += width + gap
        height = max(height, rowHeight)
    }
}

/// Where a run of pictures goes: left to right in lines, each line starting when the next picture
/// would not fit. Pure arithmetic over sizes, so the strip's wrapping is proved without a window.
enum PictureFlow {
    struct Slot: Equatable {
        var line: Int
        var x: CGFloat
        var y: CGFloat
    }

    /// One slot per size, in order, from `y` 0. A picture wider than the line still takes a line
    /// to itself.
    static func slots(sizes: [CGSize], available: CGFloat, gap: CGFloat) -> [Slot] {
        var slots: [Slot] = []
        var line = PictureLine()
        var index = 0
        for (offset, size) in sizes.enumerated() {
            if offset > 0, line.accepts(size.width, in: available) {
                slots.append(Slot(line: index, x: line.cursor, y: line.top))
                line.take(width: size.width, height: size.height, gap: gap)
                continue
            }
            let top = offset == 0 ? 0 : line.top + line.height + gap
            if offset > 0 { index += 1 }
            slots.append(Slot(line: index, x: 0, y: top))
            line = PictureLine(top: top, cursor: size.width + gap, height: size.height)
        }
        return slots
    }
}

/// The thumbnail a picture wears in the transcript: never taller than the table's bound, as wide as
/// its own proportions make it, never enlarged past its pixels and never wider than the column.
enum PictureThumb {
    /// The widest a thumbnail is drawn, so a panorama does not take the whole line.
    static let widest: CGFloat = 600

    static func size(
        pixels: CGSize, maxHeight: CGFloat, maxWidth: CGFloat
    ) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: maxHeight, height: maxHeight) }
        let scale = min(maxHeight / pixels.height, maxWidth / pixels.width, 1)
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }

    /// What a picture whose bytes have not arrived holds the room of: the proportions most of what
    /// an agent writes into a conversation has.
    static func placeholder(maxHeight: CGFloat) -> CGSize {
        CGSize(width: (maxHeight * 4 / 3).rounded(), height: maxHeight)
    }
}

/// When a rail's plate opens and closes, as pure logic over timestamps: the pointer resting on a
/// rail opens it after ``restDelay``, leaving both the rail and the plate closes it after
/// ``leaveDelay``, and Esc closes it at once. The view only reports where the pointer is and asks
/// when to look again.
struct RailHover: Equatable {
    enum Region: Equatable {
        case none
        case rail(String)
        case plate
    }

    static let restDelay: TimeInterval = 0.120
    static let leaveDelay: TimeInterval = 0.250

    private(set) var open: String?
    private var candidate: (key: String, since: TimeInterval)?
    private var leaving: TimeInterval?

    static func == (lhs: RailHover, rhs: RailHover) -> Bool {
        lhs.open == rhs.open && lhs.candidate?.key == rhs.candidate?.key
            && lhs.candidate?.since == rhs.candidate?.since && lhs.leaving == rhs.leaving
    }

    /// The pointer is on a region at a moment. Resting on the open rail or its plate cancels a
    /// close; resting on another rail starts that rail's rest.
    mutating func pointer(on region: Region, at now: TimeInterval) {
        switch region {
        case .plate:
            candidate = nil
            leaving = nil
        case .rail(let key):
            if open == key {
                candidate = nil
                leaving = nil
            } else {
                if candidate?.key != key { candidate = (key, now) }
                if open != nil, leaving == nil { leaving = now }
            }
        case .none:
            candidate = nil
            if open != nil, leaving == nil { leaving = now }
        }
    }

    /// Opens a rail without waiting for a rest: a click or a key on it.
    mutating func openNow(_ key: String) {
        open = key
        candidate = nil
        leaving = nil
    }

    mutating func escape() {
        open = nil
        candidate = nil
        leaving = nil
    }

    /// Lets the clocks run to `now`.
    mutating func advance(to now: TimeInterval) {
        if let candidate, now - candidate.since >= Self.restDelay {
            open = candidate.key
            self.candidate = nil
            leaving = nil
        }
        if let leaving, now - leaving >= Self.leaveDelay {
            open = nil
            self.leaving = nil
        }
    }

    /// When something will next change if nothing else happens, or nil when nothing is pending.
    var deadline: TimeInterval? {
        let rest = candidate.map { $0.since + Self.restDelay }
        let leave = leaving.map { $0 + Self.leaveDelay }
        switch (rest, leave) {
        case (let rest?, let leave?): return min(rest, leave)
        case (let rest?, nil): return rest
        case (nil, let leave?): return leave
        case (nil, nil): return nil
        }
    }
}

/// Where a rail's plate goes, in the coordinates of the view it floats in, which may be flipped or
/// not. Core decides which side; this places the rectangle there, clamped inside the view.
enum RailPlacement {
    static let seam: CGFloat = 2

    /// The room under a rail, down to the foot of what the reader can see: the visible rectangle
    /// less whatever floats over its bottom edge.
    static func roomBelow(rail: NSRect, visible: NSRect, bottomInset: CGFloat, flipped: Bool)
        -> CGFloat
    {
        flipped
            ? (visible.maxY - bottomInset) - rail.maxY
            : rail.minY - (visible.minY + bottomInset)
    }

    static func frame(
        rail: NSRect, plateSize: NSSize, bounds: NSRect, flipped: Bool, upward: Bool
    ) -> NSRect {
        let margin: CGFloat = 4
        let x = max(bounds.minX + margin, min(rail.minX, bounds.maxX - plateSize.width - margin))
        let above = flipped ? rail.minY - plateSize.height - seam : rail.maxY + seam
        let below = flipped ? rail.maxY + seam : rail.minY - plateSize.height - seam
        return NSRect(origin: NSPoint(x: x, y: upward ? above : below), size: plateSize)
    }
}
