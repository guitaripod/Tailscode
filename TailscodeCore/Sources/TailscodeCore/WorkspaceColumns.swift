import Foundation

/// How many of the iPad workspace's columns a window can show at once, decided from its size so
/// that no column is starved to make room for another.
///
/// The conversation is what the window is for: code, diffs and tables need about 620 points before
/// they stop wrapping into a column of fragments. So the list stands beside it only once both fit,
/// and the sidebar joins them only once all three do; below each line the column that does not fit
/// steps back to an overlay a press or a swipe from the leading edge brings out, instead of every
/// column shrinking together. A phone on its side is the exception that keeps the list: it is short
/// and very wide, and a lone transcript there would be a strip of margins.
public enum WorkspaceColumns: Equatable, Sendable {
    /// One stack, the phone's app.
    case stack
    /// The conversation alone; the list and the sidebar lay over it on demand.
    case conversation
    /// The list beside the conversation; the sidebar lays over them on demand.
    case listBeside
    /// Sidebar, list and conversation side by side.
    case all

    public static let sidebarWidth = 268.0
    public static let listWidth = 320.0
    public static let wideListWidth = 360.0
    public static let conversationMinimum = 620.0

    /// The narrowest window that holds the list and a whole conversation.
    public static let listBesideMinimum = listWidth + conversationMinimum
    /// The narrowest window that holds all three.
    public static let allMinimum = sidebarWidth + wideListWidth + conversationMinimum + 32
    /// How wide a short, wide window must be to keep the list beside a shorter conversation.
    public static let shortListBesideMinimum = 820.0
    /// How much wider than tall a window is before it counts as short.
    public static let shortAspect = 1.6

    public static func fit(width: Double, height: Double, compact: Bool) -> WorkspaceColumns {
        guard !compact else { return .stack }
        if width >= allMinimum { return .all }
        if width >= listBesideMinimum { return .listBeside }
        if width >= shortListBesideMinimum, height > 0, width >= height * shortAspect {
            return .listBeside
        }
        return .conversation
    }

    /// The list column's width in a window this wide: the full width beside a sidebar, and beside
    /// the conversation alone whatever the conversation can spare above its own comfortable width.
    public static func listColumnWidth(_ columns: WorkspaceColumns, width: Double) -> Double {
        switch columns {
        case .all: return wideListWidth
        case .listBeside:
            return min(wideListWidth, max(listWidth, width - conversationMinimum - 240))
        case .conversation, .stack: return listWidth
        }
    }
}
