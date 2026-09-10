import Foundation

/// How a pipe table's columns are sized, shared so three clients cannot each invent a different
/// answer — one capped its cells at 340 points, one at forty characters, one measured properly,
/// and the same table read as three different tables.
///
/// The arithmetic is the same everywhere and the client supplies only what its own font can say:
/// how wide each column's widest cell measures. What comes back is a width per column, and whether
/// the table fits — a table that cannot fit scrolls sideways rather than crushing its numbers.
public enum TableLayout {
    /// The space between two columns. Wide enough that a right-aligned number and the next
    /// column's first letter are never read as one word.
    public static let gap: Double = TableStyle.columnGap

    /// The narrowest a column may be *squeezed*. Below this a prose cell wraps to one word a line,
    /// which is not a column any more — past it the table scrolls instead. It is a floor on the
    /// trimming and never a width a column is grown to: a column of two-digit readings measures
    /// twenty-seven points and is twenty-seven points wide, because the alternative is what a
    /// table of readings used to look like — a `Ch`, a `Sig` and a `Width` each standing alone in
    /// the middle of an inch of nothing.
    public static let minimumColumn: Double = 56

    /// Column widths for the natural measures given, inside `fitting`.
    ///
    /// Every column is exactly its own natural measure while the table fits. If it does not, the
    /// widest give way first and share what is left equally: a column narrower than its even share keeps every
    /// point of its measure, and the wide ones are all trimmed to the same cap. A column of dates
    /// therefore never loses room so that a column of prose can keep it, and two prose columns of
    /// the same width are trimmed together rather than one collapsing while the other stands.
    ///
    /// Nothing is trimmed below `minimum` — under it a cell wraps to one word a line, which is not
    /// a column any more. A table whose columns are all at the floor and still too wide is handed
    /// back too wide on purpose: it is the client's business to scroll it, because a number
    /// squeezed to three characters is worse than a number the reader has to reach for.
    ///
    /// - Parameter rigid: which columns hold nothing worth breaking — addresses, codes, short
    ///   readings (`MarkdownTable.rigidColumns`). Taking width off one of those buys no folding;
    ///   it hyphenates a token that was never a word, or stacks `MHz` under `2437`. So a rigid
    ///   column keeps its whole measure and the prose columns pay for the room, which is the
    ///   trade a person would make by hand.
    /// - Parameter floors: what each column's own widest unbreakable run measures
    ///   (`MarkdownTable.unbreakable`). A column is never squeezed under it, because below it a
    ///   cell stops folding and starts breaking — a number split across two lines is not a
    ///   number. The design floor and this one are both respected, whichever is larger.
    public static func widths(
        natural: [Double], fitting: Double, gap: Double = gap, minimum: Double = minimumColumn,
        rigid: [Bool] = [], floors: [Double] = []
    ) -> [Double] {
        guard !natural.isEmpty else { return [] }
        let base = natural
        let budget = fitting - gap * Double(base.count - 1)
        guard budget > 0, base.reduce(0, +) > budget else { return base }
        let held = Set(base.indices.filter { rigid.indices.contains($0) && rigid[$0] })
        let foldable = base.indices.filter { !held.contains($0) }
        guard !foldable.isEmpty else { return base }
        var remaining = max(0, budget - held.reduce(0) { $0 + base[$1] })
        var wide = foldable.count
        for width in foldable.map({ base[$0] }).sorted() {
            guard width <= remaining / Double(wide) else { break }
            remaining -= width
            wide -= 1
        }
        guard wide > 0 else { return base }
        let cap = remaining / Double(wide)
        let folded = base.indices.map { index -> Double in
            guard !held.contains(index) else { return base[index] }
            let floor = max(minimum, index < floors.count ? floors[index] : 0)
            return min(base[index], max(cap, floor))
        }
        // Folding is only ever worth the height it costs when it makes the table fit. A table that
        // is going to be scrolled either way is better read short and wide than tall and slightly
        // less wide: squeezing a column of cipher suites into fifty-six points to save an inch of
        // a table already an inch too wide buys four lines a row and nothing else.
        return width(of: folded, gap: gap) <= fitting + 0.5 ? folded : base
    }

    /// What the whole table measures at those widths.
    public static func width(of widths: [Double], gap: Double = gap) -> Double {
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + gap * Double(widths.count - 1)
    }

    /// Whether the table has to scroll sideways to be read whole.
    public static func overflows(_ widths: [Double], fitting: Double, gap: Double = gap) -> Bool {
        width(of: widths, gap: gap) > fitting + 0.5
    }

    /// The widths to actually use while a table is still arriving: never narrower than they were
    /// a moment ago.
    ///
    /// A table grows a row at a time, and each row can make a column wider — which makes the
    /// squeeze take more from that column, which gives room back to another, which moves every
    /// column on the screen. The reader is trying to read the rows already there. So a column may
    /// widen under the writing and may never narrow: the table only ever opens out, and the
    /// arrangement it settles into is the one it had all along. When the answer is finished the
    /// clean measure is taken again, once, with nothing left to move.
    public static func settled(_ widths: [Double], since previous: [Double]) -> [Double] {
        guard !previous.isEmpty else { return widths }
        return widths.enumerated().map { index, width in
            index < previous.count ? max(width, previous[index]) : width
        }
    }
}
