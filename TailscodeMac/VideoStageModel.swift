import AVFoundation
import AppKit
import TailscodeCore

struct VideoClipHold: Equatable {
    let id: String
    let url: URL
}

/// Everything the Video stage draws, decided once by the lane from the board so the stage, the
/// verbs, the dock and the shelf can never disagree. The stage holds no forge of its own: it is
/// handed a model on every change and redraws only what that change touches.
struct VideoStageModel {
    var state: StudioVideoState = .empty
    var size: ForgeSize = .landscape
    var caption = ""
    var sentence = ""
    var sketchCaption = ""
    var segments: [StudioProgressLine.Segment] = []
    var clip: VideoClipHold?
    var held: CGImage?
    var sketch: CGImage?
    var verbs: [StudioStageVerb] = []
    var spoken = ""
    var needsRenderer = false
    var heldIsBackdrop = false
    var invitationTitle = ""
    var invitationBody = ""
    var landed: String?
    var continuationTitle = ""
    var continuationBody = ""
    var continuationAction = ""
    var arriving = false
}

/// The Video stage: the clip owns the window. An opaque canvas with a sixteen-point corner, the
/// clip aspect-fit inside it with a margin all round and clear of the dock that floats over its
/// foot. The rectangle is decided before a render starts, from the size that was asked for, so the
/// machine's sketch fills it and the clip lands in it and nothing moves when it arrives.
///
/// It says what `StudioVideoState` says: an invitation when empty, the first frame while drafting,
/// one sentence on a glyph that breathes while the machine works out what it was asked, the
/// machine's own sketch while it samples with a line along the sketch's edge — one segment for each
/// pass the graph samples in — the clip once it lands, crossfaded from the sketch in one 240 ms
/// ease-out or instantly under reduced motion, and a failure in the failure tone, perfectly still,
/// with the one thing that fixes it. A finished clip plays in place, loops, and is muted unless it
/// has sound; there is no player chrome, because the verbs capsule is the only floating control the
/// picture carries. A clip that has just landed is played by the stage itself, once, as a clip the
/// person had chosen would be, and a clip about to be continued is held dimmed behind a card that
/// says what the next one opens on.
