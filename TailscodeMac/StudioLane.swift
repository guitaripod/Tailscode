import AppKit
import TailscodeCore

/// The two things the Studio makes. The lane switch names both, the shelf and the machine pill stay
/// put while it moves, and the lane decides everything below the toolbar's centre — what the stage
/// holds, what the dock asks, which tiles the shelf draws and what the machine can do.
enum StudioLaneID: Int, CaseIterable, Sendable {
    case image
    case video

    var title: String {
        switch self {
        case .image: return Localized.text("Image")
        case .video: return Localized.text("Video")
        }
    }
}

/// The one fact the toolbar's pill wears: which machine, the most useful thing to say about it, the
/// tone that fact has and whether it can paint at all. A lane reads this off whatever it renders on,
/// so the pill never knows which lane it is serving.
struct StudioMachineFact: Equatable, Sendable {
    let name: String
    let line: String
    let tone: ActivityTone?
    let canPaint: Bool
    let isWorking: Bool

    var spoken: String { "\(name), \(line)" }
}

/// What a lane tells the shell changed, so a surface redraws only that: a sketch is one layer's
/// contents, a step is one line and one bar, and a shelf that rebuilt itself for either would spend
/// a render on layout.
enum StudioLaneChange: Equatable, Sendable {
    case everything
    case shelf
    case tile(String)
    case sketch
    case progress
}

/// A tile dragged out of the shelf, as the bytes the machine wrote and a name to give them.
struct StudioDragFile: Sendable {
    let name: String
    let data: Data
}

/// A verb a shelf tile offers on right-click, and that a dragged tile or a pressed key resolves to.
enum StudioTileVerb: Equatable, Sendable {
    case putOnStage
    case action(ImageGenAction)
}

/// The stage as a lane draws it: the shell lays it out and tells it how much of its foot the dock
/// has taken, and the lane draws the picture, the sketch or the clip in what is left.
@MainActor
protocol StudioStaging: AnyObject {
    var bottomReserve: CGFloat { get set }
}

/// The dock as a lane draws it. The shell asks how tall it wants to be for a width and whether its
/// second row has folded, and is told when it grows — a words box that takes a third line grows
/// upward over the stage rather than moving the picture.
@MainActor
protocol StudioDocking: AnyObject {
    var foldsChips: Bool { get set }
    var onHeightChange: (() -> Void)? { get set }
    func preferredHeight(forWidth width: CGFloat) -> CGFloat
    var baseHeight: CGFloat { get }
    func focusWords()
    var wordsAreFocused: Bool { get }
    func take(brief words: String)
}

/// A lane, as the shell sees it.
///
/// The Video lane of the next task plugs in by writing a type that conforms and adding it to
/// `StudioShell.lanes`; nothing in the shell, the shelf or the toolbar names the Image lane.
@MainActor
protocol StudioLane: AnyObject {
    var id: StudioLaneID { get }
    var stage: NSView & StudioStaging { get }
    var dock: NSView & StudioDocking { get }
    var shelf: [StudioShelfItem] { get }
    var selectedTile: String? { get }
    var shelfNote: String? { get }
    var machine: StudioMachineFact { get }
    var queueCount: Int { get }
    var jobSketch: CGImage? { get }
    var jobBadge: String? { get }
    var jobFraction: Double? { get }
    var onNotice: ((String) -> Void)? { get set }
    func prepare()
    func offers(_ key: StudioKey) -> Bool
    func perform(_ key: StudioKey)
    func select(tile id: String)
    func tileThumbnail(_ item: StudioShelfItem) async -> NSImage?
    func tileFileName(_ item: StudioShelfItem) -> String
    func tileFile(_ item: StudioShelfItem) async -> StudioDragFile?
    func tileVerbs(for item: StudioShelfItem) -> [StudioTileVerb]
    func perform(_ verb: StudioTileVerb, on item: StudioShelfItem)
    func tileTooltip(_ item: StudioShelfItem) -> String
    func watch(_ owner: AnyObject, _ block: @escaping (StudioLaneChange) -> Void)
    func unwatch(_ owner: AnyObject)
    func presentMachine(from anchor: NSView)
}
