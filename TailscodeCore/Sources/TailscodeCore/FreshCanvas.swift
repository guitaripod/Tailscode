import Foundation

/// The arithmetic of a prompt rising to the top of the window so the answer streams onto an empty
/// canvas. A transcript scrolled to its end keeps the newest words at the bottom, which puts the
/// question a person just asked directly above the box they typed it in and the answer nowhere
/// yet; what they want is the question as a heading and the page under it empty. That needs room
/// below the last row that the content does not have, so the client adds it — enough that the
/// prompt can rest at the top with the answer's first line under it — and takes it back as the
/// answer grows into it, so the end of the conversation never floats above the end of the window.
///
/// The prompt is the whole of what was sent: a picture clipped to the words is drawn above them,
/// and pinning the words alone leaves the picture hidden one line above the top edge. So the
/// block a client measures runs from the first row of the send to the last.
///
/// What grows into the room is what the reader can see, not what the client has laid out. The
/// live row is measured in full when its text arrives — everything past the reveal is drawn at
/// zero alpha rather than cut off — so the layout is always ahead of the writing, and a canvas
/// that shrank by the layout let go while the visible words were still mid-screen and then
/// followed an end nobody could see. Every reading here therefore takes `unrevealed`: the height
/// of the live row past its reveal, which a client subtracts from the content's end.
public enum FreshCanvas {
    /// How far below the top edge the prompt rests once it has risen.
    public static let headroom: Double = 12

    /// The room to hold under the transcript so the prompt can rest at the headroom — measured
    /// from the page itself rather than from a client's own account of its content. Zero once what
    /// is under the prompt fills the window on its own.
    ///
    /// A client knows four things exactly: where the prompt stands, how tall the window is, how
    /// far the page can already scroll, and how much room it is already holding. Everything else —
    /// the height of the content, the gap a stack puts between its children, an inset counted once
    /// or twice, a row still standing at its estimate — is a re-derivation, and every one of them
    /// was a few points away from a room that came up short, a scroll clamped that many points
    /// early, and a prompt that stopped below the headroom and stayed there. So this asks the page
    /// instead; and because what it returns *corrects* the room already being held, it converges
    /// on the right answer however wrong the last one was.
    ///
    /// `end` is where the page would end with no room made: its whole scrollable extent — content
    /// plus every inset — less the room already held and less the part of the live row laid out
    /// ahead of the reveal, since text nobody has been shown yet does not fill a window. It has to
    /// exclude the room: an answer that measured the page *including* the room it was asked to
    /// size would ask for that much again on the next pass, and again on the one after.
    public static func room(promptTop: Double, viewport: Double, end: Double) -> Double {
        max(0, promptTop - headroom + viewport - end)
    }

    /// Whether the canvas is still holding room, so a client knows when to stop asking. It says
    /// nothing about whether the prompt should rise — see `reaches` — only whether there is still
    /// room being made under it.
    public static func holds(room: Double) -> Bool { room > 0 }

    /// The offset that puts the prompt at the top: its own top less the headroom, never past what
    /// the content — padded — allows.
    ///
    /// Read again after every layout for as long as the canvas holds, never once at the start.
    /// The room a client asks for lands a frame after it is asked for, a row that measures itself
    /// is laid out at an estimate until it does, and the server's own account of the send replaces
    /// the rows this device drew — each of those moves the prompt under a scroll that was aimed
    /// once and never looked again, and the prompt ends up somewhere down the page with no one
    /// left to notice.
    public static func offset(promptTop: Double, contentHeight: Double, viewport: Double) -> Double {
        let wanted = promptTop - headroom
        let limit = max(0, contentHeight - viewport)
        return max(0, min(wanted, limit))
    }

    /// How far the prompt is from where it belongs: positive while it still sits below the
    /// headroom, negative once it has gone past. The top is the content's own coordinate and the
    /// offset is the scroll's, so the difference is where the prompt stands on screen.
    public static func drift(promptTop: Double, offset: Double) -> Double {
        promptTop - offset - headroom
    }

    /// Whether the rise has actually arrived. A landing is checked rather than assumed, because
    /// every reason it misses is invisible to the code that asked for it.
    public static func hasLanded(promptTop: Double, offset: Double) -> Bool {
        abs(drift(promptTop: promptTop, offset: offset)) <= landing
    }

    /// How near the headroom counts as being there. Under a point is under a pixel on every
    /// display this app runs on.
    public static let landing: Double = 1

    /// Whether the page — with whatever room the canvas is making — is long enough to put the
    /// prompt at the headroom at all. This is the only thing that can stop a rise.
    ///
    /// It is emphatically not `holds`: room is half of a rise, and a conversation tall enough to
    /// lift the prompt out of its own height needs none. A client that read *no room needed* as
    /// *nothing to do* skipped the rise on exactly the transcripts where a person has most to
    /// lose by it — the long ones, where the question just asked is otherwise buried at the foot
    /// of a page they have been reading all morning.
    public static func reaches(promptTop: Double, contentHeight: Double, viewport: Double) -> Bool {
        offset(promptTop: promptTop, contentHeight: contentHeight, viewport: viewport)
            >= promptTop - headroom - landing
    }

    /// How long a client keeps asking for geometry that is not there yet before it gives the rise
    /// up. A row appended this frame is drawn on the next at the earliest and measured on the one
    /// after; a rise that read a missing row as an answer never happened at all. Long enough to
    /// outlast a slow frame and a re-layout, short enough that nothing arrives late enough to
    /// read as the page moving on its own.
    public static let patience: Double = 1.0

    /// Where the end of the visible conversation is: the content's end less what the live row has
    /// laid out ahead of its reveal.
    public static func visibleEnd(contentHeight: Double, unrevealed: Double) -> Double {
        max(0, contentHeight - max(0, unrevealed))
    }

    /// The offset that keeps the visible end at the bottom of the viewport while an answer is
    /// being written — never past the content, never before its start. A client following the
    /// bottom moves here on every frame the reveal advances, so the page is pushed up by the
    /// writing itself rather than by the layout that ran ahead of it.
    public static func followOffset(visibleEnd: Double, viewport: Double, contentHeight: Double)
        -> Double
    {
        let limit = max(0, contentHeight - viewport)
        return max(0, min(visibleEnd - viewport, limit))
    }

    /// How far the reader is from the visible end, which is the reading `isNearBottom` must take
    /// while an answer is being written: measured against the laid-out end, a reader sitting on
    /// the last written word looks scrolled away by exactly the text they have not been shown.
    public static func distanceFromVisibleEnd(
        offset: Double, viewport: Double, contentHeight: Double, unrevealed: Double
    ) -> Double {
        let end = visibleEnd(contentHeight: contentHeight, unrevealed: unrevealed)
        guard end > viewport else { return 0 }
        return max(0, end - viewport - offset)
    }

    /// How long the transcript takes to settle on a new follow target. The written end moves in
    /// steps of a line — a glyph is on one line or the next — and a viewport that jumped by a
    /// line every time the reveal crossed one read as the page twitching under the writing. So
    /// the offset eases toward where the writing is rather than landing on it, on a constant
    /// short enough that the last written line is never more than a moment from the bottom.
    public static let followTime: Double = 0.14

    /// One frame of that easing: where the offset should be `elapsed` seconds after being at
    /// `current` with `target` as its goal. Lands exactly once within half a point, so a settled
    /// follow stops asking. Never moves back: the writing only grows, and a target behind the
    /// offset — a transient of a layout that has not caught up — is a frame to wait through, not
    /// a place to go.
    public static func glide(current: Double, target: Double, elapsed: Double) -> Double {
        guard target > current else { return current }
        if target - current < 0.5 || elapsed <= 0 { return target }
        let next = current + (target - current) * (1 - exp(-elapsed / followTime))
        return target - next < 0.5 ? target : next
    }
}
