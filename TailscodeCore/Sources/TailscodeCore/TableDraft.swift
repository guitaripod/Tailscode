import Foundation

/// A table is drawn once it is whole.
///
/// A table arriving a row at a time is a table *measured* a row at a time: every cell laid out
/// again in the client's own face, every column re-fitted, the card's height re-negotiated with
/// the transcript — and all of it inside the one layout pass the answer beside it is also being
/// painted in. So the cost never stays in the table. On a wide one it is most of a frame's budget,
/// and what a reader sees is the whole window stuttering, in time with the writing.
///
/// So while a table is being written, nothing about it is measured. Its own card stands in its
/// place saying what has landed — a sweep, because something is being turned over, and a count,
/// because the count is the only fact there is yet — and the rows are held. The moment the table
/// is whole it is built once and washed in down its own bands (`TableEntrance`), which is a change
/// in light rather than in layout and costs one multiply per band per frame.
///
/// This is the one place the app deliberately shows less than it has, so it is worth saying why:
/// a table half-written is not a table anybody can read — every arrival moves the columns under
/// the rows already there — while a window that stutters is felt on every other row on the screen.
/// Holding the rows for a second costs a reader nothing and gives the rest of the answer its
/// frames back.
public struct TableDraft: Hashable, Sendable {
    public let columnCount: Int
    public let rowCount: Int

    public init(columnCount: Int, rowCount: Int) {
        self.columnCount = max(0, columnCount)
        self.rowCount = max(0, rowCount)
    }

    public init(_ table: MarkdownTable) {
        self.init(columnCount: table.columnCount, rowCount: table.rows.count)
    }

    /// Whether the table in a segment is still being written: it is the last thing in a message
    /// the server has not finished. A table with anything at all after it is finished, whatever
    /// the turn is still doing — the model has moved on and its rows will not change again.
    public static func isGrowing(segment index: Int, of count: Int, sealed: Bool) -> Bool {
        !sealed && index == count - 1
    }

    /// The mark the card wears: the same one a row wears while the work it names is still open, so
    /// a table being turned over moves like every other open thing in the window — a sweep, in the
    /// live tone — and stops when the desk asks for less motion. The vocabulary's answer rather
    /// than this card's, and no client picks a symbol of its own.
    public static let mark = ActivityIcon.openWork

    public static var motion: ActivityMotion { mark.motion }

    public var title: String { Localized.text("Building a table") }

    /// What has landed so far, or nil while there is nothing to report — a header row on its own
    /// is a table that has not said anything yet, and a card claiming "0 rows" reads as a failure
    /// rather than as a start.
    public var detail: String? {
        guard rowCount > 0 else { return nil }
        return rowCount == 1
            ? Localized.text("1 row")
            : Localized.text("%d rows", rowCount)
    }

    /// The same fact in words, for a reader who cannot see the sweep.
    public var reading: String {
        guard let detail else { return Localized.text("A table is being written.") }
        return Localized.text("A table is being written. %@ so far.", detail)
    }
}

/// How a finished table arrives: a wash of light down its own bands, and never a change of size.
///
/// The card is already standing — it was the draft — so the entrance has nothing to move. Band 0
/// is the header and the body rows follow it, each one lagging the one above by a share of `lead`
/// rather than by a fixed step, so a table of four rows and a table of forty arrive in the same
/// beat instead of the long one taking a second and a half to finish.
public enum TableEntrance {
    /// How long one band takes to come up.
    public static let duration: TimeInterval = 0.34

    /// How far the last band lags the first.
    public static let lead: TimeInterval = 0.22

    /// The whole entrance, after which a client stops its clock: a settled table is a still one.
    public static var span: TimeInterval { duration + lead }

    /// One band's opacity at `elapsed` seconds into the entrance, in `0...1`.
    public static func opacity(band: Int, of bands: Int, elapsed: TimeInterval) -> Double {
        guard bands > 0 else { return 1 }
        let index = min(max(0, band), bands - 1)
        let share = bands > 1 ? Double(index) / Double(bands - 1) : 0
        let progress = (elapsed - lead * share) / duration
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        let remaining = 1 - progress
        return 1 - remaining * remaining * remaining
    }

    public static func isFinished(_ elapsed: TimeInterval) -> Bool { elapsed >= span }
}
