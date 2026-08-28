import Foundation

/// The arithmetic of a prompt rising to the top of the window so the answer streams onto an empty
/// canvas. A transcript scrolled to its end keeps the newest words at the bottom, which puts the
/// question a person just asked directly above the box they typed it in and the answer nowhere
/// yet; what they want is the question as a heading and the page under it empty. That needs room
/// below the last row that the content does not have, so the client adds it — enough that the
/// prompt can rest at the top with the answer's first line under it — and takes it back as the
/// answer grows into it, so the end of the conversation never floats above the end of the window.
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
}
