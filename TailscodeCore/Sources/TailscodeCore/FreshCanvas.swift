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

    /// The padding to add under the transcript so a prompt `prompt` tall, with `below` already
    /// under it, can sit `headroom` under the top of a viewport `viewport` tall. Zero once what is
    /// under the prompt fills the window on its own.
    public static func padding(viewport: Double, prompt: Double, below: Double) -> Double {
        max(0, viewport - headroom - prompt - below)
    }

    /// Whether the canvas is still holding room, so a client knows when to stop asking.
    public static func holds(viewport: Double, prompt: Double, below: Double) -> Bool {
        padding(viewport: viewport, prompt: prompt, below: below) > 0
    }

    /// The offset that puts the prompt at the top: its own top less the headroom, never past what
    /// the content — padded — allows.
    public static func offset(promptTop: Double, contentHeight: Double, viewport: Double) -> Double {
        let wanted = promptTop - headroom
        let limit = max(0, contentHeight - viewport)
        return max(0, min(wanted, limit))
    }

    /// What sits under the prompt that a reader can see: the content past the prompt's bottom
    /// edge, less the part of the live row that has not been written yet.
    public static func below(contentHeight: Double, promptBottom: Double, unrevealed: Double)
        -> Double
    {
        max(0, contentHeight - promptBottom - max(0, unrevealed))
    }

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
