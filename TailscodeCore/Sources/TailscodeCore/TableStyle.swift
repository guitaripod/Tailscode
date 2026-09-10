import Foundation

/// How a pipe table is *drawn*, decided once for three clients, so a table is one object on a
/// phone, a Linux pane and a Mac window rather than three arrangements of the same cells.
///
/// A table used to be a bold header over a hairline with the rows loose underneath, and on a wide
/// pane that is not a table — it is a field of words. Sixteen rows of eight sparse columns leave a
/// reader tracking one row across two feet of screen with nothing but the gap between the lines to
/// go on, and a cell that folded put half of itself on a line that belongs, as far as the eye can
/// tell, to the row below. So the table is an object with edges: a bordered card holding a header
/// band that is visibly not the body, a rule between them, and every other row washed. Row banding
/// is the one device that makes a wide row followable without drawing a cage around every cell, and
/// it is what carries a folded cell too — the fold stays inside its own band.
///
/// Every number here is geometry or a strength. A client supplies its own ink and its own canvas
/// and decides nothing else: which columns are figures, which are code, which one names the row
/// and where each one sits is `MarkdownTable`'s, and how wide each is is `TableLayout`'s.
public enum TableStyle {
    /// The space between two columns. The bands carry the rows, so the gap only has to keep a
    /// right-aligned number from being read into the next column's first letter.
    public static let columnGap: Double = 16

    /// The card's own inset: how far the first column's ink sits from the border, and the last
    /// column's from the other side. A band that ran to the border would read as a fill rather
    /// than as a row.
    public static let edge: Double = 12

    /// Air above and below a body row's ink. Small, because a table is scanned rather than read,
    /// and the wash already separates the rows.
    public static let rowPadding: Double = 5

    /// Air above and below the header's ink. Wider than a row's, because the band is a lid.
    public static let headerPadding: Double = 8

    /// The card's corner.
    public static let radius: Double = 10

    /// The card's outline, as a strength on the theme's **ink** rather than on its hairline
    /// colour — a hairline is drawn to disappear against a canvas, and four of them meeting at a
    /// corner is the one place a table needs a line that does not.
    public static let border: Double = 0.14

    /// The rule under the header, on the same ink. It is the one line in the table that has to
    /// hold: it says the words above it name the columns rather than being the first row of data.
    public static let headerRule: Double = 0.22

    /// The wash under the header band, as a strength on the theme's accent. Enough to read as a
    /// different surface, far too little to compete with the ink standing on it.
    public static let headerWash: Double = 0.07

    /// The wash on every second body row, as a strength on the theme's ink over its canvas. The
    /// single number this whole design turns on: below about a twentieth it stops guiding the eye,
    /// and above about a tenth the table starts looking like a spreadsheet.
    public static let stripe: Double = 0.05

    /// How wide the fade at a table's trailing edge is when there is more table off the side. A
    /// column cut off at a border reads as a bug; the same column dissolving reads as an invitation
    /// to push it.
    public static let fade: Double = 28

    /// Which body rows carry the wash. The first row is clean, so the header's band and the first
    /// row are never two bands in a row.
    public static func stripes(row: Int) -> Bool { row % 2 == 1 }

    /// The heavier voice for the first column, when the first column names its row
    /// (`MarkdownTable.namesItsRows`) — the type ramp's answer to "a name outweighs its detail".
    public static func role(header: Bool, key: Bool) -> TypeRole {
        if header { return .tableHeader }
        return key ? .tableKey : .tableCell
    }
}
