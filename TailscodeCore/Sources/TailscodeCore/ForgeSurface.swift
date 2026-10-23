import CodingAgentKit
import Foundation

/// The control that opens the forge, and what it says on each of the three desks.
///
/// Video generation was reachable through a settings menu on one client and a menu-bar item on
/// another, which is where a preference lives rather than where an action does. It is an action —
/// the same weight as starting a chat — so it gets a control of its own beside the app's other
/// primary ones, wearing one title, one symbol and one glyph everywhere.
public enum ForgeEntryPoint {
    public static var title: String { ForgeBoard.heading }

    /// The title on a menu row, where the ellipsis is the convention for "this opens something".
    public static var menuTitle: String { Localized.text("Video…") }

    /// SF Symbols for the Apple clients; the text clients map it to `glyph`, the way every other
    /// toolkit-free icon in this package is carried.
    public static var symbol: String { "film.stack" }

    public static var glyph: String { "▶" }

    /// What the control promises, which is a different promise before a renderer exists: one opens
    /// a box you describe a video in, the other opens the setup that makes that possible.
    public static func tooltip(configured: Bool) -> String {
        configured
            ? Localized.text("Describe a video and watch it be made")
            : Localized.text("Set up the machine that makes videos")
    }

    public static func accessibilityLabel(rendering: Bool) -> String {
        rendering ? Localized.text("Video — rendering") : title
    }

    /// The mark the control wears while a render is out, so a person who closed the surface can
    /// still see that the other machine is working. Nil when nothing is running — a badge on an
    /// idle control is a decoration, and this vocabulary has none.
    public static func activity(rendering: Bool) -> ActivityKind? {
        rendering ? .working : nil
    }
}

/// How the forge is presented, which is the thing every desktop had wrong.
///
/// A render is a task you start, watch and collect. It is not a place you work, so it does not earn
/// half of a window the way a second conversation does — tiling it beside a chat spends the
/// transcript's width on a surface nobody types into for four minutes, and leaves the pane behind
/// afterwards. So it opens over the window and closes back to it, on every desk: a modal on the
/// desktops, a presented screen on the phone.
///
/// The one thing dismissal must not do is stop the render. The job lives above the surface — the
/// way `ForgeRunner` already holds it on iOS — so closing is closing a window, not cancelling four
/// minutes of somebody else's card, and the surface says so while a render is out.
public enum ForgeSurface {
    public static var title: String { ForgeEntryPoint.title }

    public static var subtitle: String { ForgeBoard.notice }

    public static var dismissTitle: String { Localized.text("Done") }

    /// What closing means while something is rendering. Nil when nothing is — there is nothing to
    /// reassure anybody about.
    public static func dismissNote(rendering: Bool) -> String? {
        guard rendering else { return nil }
        return Localized.text(
            "Closing this leaves the render running on the machine with the card. Come back and it will still be here."
        )
    }

    /// The size the modal opens at on a desktop, so a Mac sheet and a GTK window are the same
    /// surface rather than two shapes that happen to share a name. Landscape: the stage is the
    /// room and the controls sit beside it, which is how a studio is read rather than a form.
    public static let preferredWidth: Double = 1080
    public static let preferredHeight: Double = 680
    public static let minimumWidth: Double = 760
    public static let minimumHeight: Double = 500
}

/// How the forge is composed on screen. The board is still the four sections — this is the drawing
/// contract, so a phone, a Mac and a Linux desktop put the same things in the same places: the
/// stage is the room, the words are typed once, the settings walk as chips, and what was made is a
/// strip of clips rather than another list.
public enum ForgeStudio {
    /// The walkable settings worn as chips — everything a tap can change.
    public static var chips: [ForgeField] {
        ForgeField.allCases.filter(\.isCyclable)
    }

    /// Share of a desktop given to the stage. The rest is the control column.
    public static let stageShare: Double = 0.58

    /// Width the control column asks for, so the prompt has a line length and the chips wrap
    /// rather than stretch.
    public static let controlWidth: Double = 360

    /// Height of the filmstrip under the stage. Tall enough for a thumb and a caption, short
    /// enough that the stage stays the room.
    public static let filmHeight: Double = 92
}
