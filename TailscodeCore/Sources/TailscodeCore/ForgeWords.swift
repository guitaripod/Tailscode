import Foundation

/// Words the board says about the sound, the start picture and the player, in one place so the
/// three clients cannot each invent a placeholder.
public enum ForgeWords {
    public static var soundUnset: String { Localized.text("Whatever fits the picture") }
    public static var soundHint: String {
        Localized.text("Every clip comes with sound. Say what is heard, or let the model decide")
    }
    public static var soundPlaceholder: String {
        Localized.text("What is heard: rain on a tin roof, a distant train…")
    }
    public static var negativeIgnoredHint: String {
        Localized.text("%@ runs without guidance, so this changes nothing", ForgeModel.label)
    }
    public static var recentTitle: String { Localized.text("Recent clips") }
    public static var frameUnset: String { Localized.text("The words alone") }
    public static var frameHint: String {
        Localized.text("A picture the clip opens on, or the end of a clip already made")
    }
    public static var pickFileTitle: String { Localized.text("A picture file…") }
    public static var pickFileHint: String { Localized.text("Sent to the machine with the render") }
    public static func continueTitle(_ entry: ForgeEntry) -> String {
        Localized.text("Where “%@” ended", entry.title)
    }
    public static var continueHint: String { Localized.text("The last frame of that clip opens this one") }
    public static var noFrameTitle: String { Localized.text("No picture") }
    public static var extendTitle: String { Localized.text("Continue it") }
    public static var extendHint: String {
        Localized.text("Start the next clip where this one ended, with these words to edit")
    }
    /// The stage's card while a continuation waits to be written: which clip it opens on, said as
    /// the first thing the person sees rather than as a chip they have to hover.
    public static func continuingTitle(_ entry: ForgeEntry?) -> String {
        guard let entry else { return Localized.text("Continuing a clip") }
        return Localized.text("Continuing “%@”", entry.title)
    }
    public static var continuingBody: String {
        Localized.text(
            "The next clip opens on the last frame of this one. Change the words to say what happens next, then render"
        )
    }
    public static var continuingFreshTitle: String { Localized.text("Start fresh instead") }
    /// A line for the moment Continue it is pressed, wherever it was pressed from.
    public static func continuingNotice(_ entry: ForgeEntry) -> String {
        Localized.text("The next clip opens where “%@” ended — change the words, then render", entry.title)
    }
    public static func continueElsewhere(_ machine: String) -> String {
        Localized.text("That clip is on %@, not on the machine rendering now", machine)
    }
    public static var animateTitle: String { Localized.text("Animate this") }
    public static var animateHint: String { Localized.text("Open the video forge with this picture as the first frame") }
    /// The mark on a playing clip: the clip has a soundtrack, and whether it is being heard.
    public static var soundOnMark: String { Localized.text("sound") }
    public static var soundOffMark: String { Localized.text("muted") }
    public static var soundToggleHint: String { Localized.text("m mutes and unmutes") }
    /// The caption over a sketch on the stage, so it is never mistaken for the clip.
    public static func sketchCaption(_ job: ForgeJob) -> String {
        guard job.samplerSteps > 0 else { return Localized.text("Sketch") }
        return Localized.text(
            "Sketch · %@ · step %@ of %@", job.stageName ?? "", "\(min(job.samplerStep, job.samplerSteps))",
            "\(job.samplerSteps)")
    }
    public static var sketchNote: String { Localized.text("the machine's own sketch of the first frame so far") }
}
