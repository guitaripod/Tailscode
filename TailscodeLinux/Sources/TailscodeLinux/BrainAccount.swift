import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// A wheel controller that sees each notch after the widgets inside have had it.
extension Gtk {
    static func onScrollBubble(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable (Double) -> Bool
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(ScrollBox(handler)).toOpaque()
        let callback: @convention(c) (Double, UnsafeMutableRawPointer?) -> gboolean = { dy, raw in
            guard let raw else { return 0 }
            return Unmanaged<ScrollBox>.fromOpaque(raw).takeUnretainedValue().handler(dy) ? 1 : 0
        }
        tailscode_connect_scroll_bubble(widget, callback, box)
    }
}

/// The right side of an open brain: the agent talking to you. A column of what it said, what it
/// thought, the work it did folded to a line, and the answer that closes the turn, with whatever
/// it is waiting on you for pinned above it and the step under the cursor opened inside the story.
///
/// The column scrolls and never owns more widgets than the window it shows: items are measured
/// when they are made, estimated while they are not, and only the ones near the viewport exist at
/// all, so a turn of two thousand steps costs what a screenful costs. The scroll is the
/// account's own (a target the wheel moves and the clock eases toward), because an item that
/// changes height under a reader must move the offset with it, and only the thing that knows the
/// offset can do that.
final class BrainAccount: @unchecked Sendable {
    unowned let owner: BrainView
    let ref: WeakBrainView
    /// Holds the header, the pinned ask, the story, the footer and the pill.
    let root: UnsafeMutablePointer<GtkWidget>
    /// Holds the items that exist; places them by the offsets this class keeps.
    let story: UnsafeMutablePointer<GtkWidget>
    /// The entity's header, full width, with the rule under it; `headerBox` is what it holds.
    let header: UnsafeMutablePointer<GtkWidget>
    let headerBox: UnsafeMutablePointer<GtkWidget>
    let footer: UnsafeMutablePointer<GtkWidget>
    let pill: UnsafeMutablePointer<GtkWidget>
    let scrollbar: UnsafeMutablePointer<GtkWidget>

    /// A part of the account that stays above the story: the ask, the Now line, a running plan.
    final class Pin {
        let widget: UnsafeMutablePointer<GtkWidget>
        var height = 0.0
        let signature: String
        init(widget: UnsafeMutablePointer<GtkWidget>, signature: String) {
            self.widget = widget
            self.signature = signature
        }
    }

    var askPin: Pin?
    var nowPin: Pin?
    var planPin: Pin?
    var askWidget: UnsafeMutablePointer<GtkWidget>? { askPin?.widget }
    var askHeight: Double { askPin?.height ?? 0 }
    var askSignature: String { askPin?.signature ?? "" }
    var nowSignature = ""
    var planSignature = ""
    var planOpenOverride: Bool?
    var pinnedPlanCompact = false
    var askDotWidget: Gtk.WeakWidget?
    var nowDotWidget: Gtk.WeakWidget?
    var headerStamp = ""
    var filterWord: String?
    var lastActivityAt: Date?
    var lastActivityMark = ""
    var headerHeight = 40.0
    var headerWasNarrow = false
    var lastSecond = 0.0
    lazy var askedLine = Self.lineHeight("bn-asked-text")

    var account: NeuralAccount
    var entries: [AccountEntry] = []
    var entryIndex: [String: Int] = [:]
    var cells: [String: AccountCell] = [:]
    var heights: [String: Double] = [:]
    var offsets: [Double] = []
    var total = 0.0

    var unfolded = Set<String>()
    var expandedText = Set<String>()
    var rowCaps: [String: Int] = [:]

    var scroll = 0.0
    var target = 0.0
    var viewHeight = 0.0
    var storyWidth = 0.0
    var boxWidth = 0.0
    var lastTick = 0.0
    var arrivals: [String: Double] = [:]
    var justNow: [String: Double] = [:]
    var knownIDs = Set<String>()
    var seeded = false
    var pendingReveal: (id: String, pad: Double)?
    var lastCursor: String?
    var suppressReveal: String?
    var realizeScheduled = false
    var refreshTicket = 0
    var lastRefresh = 0.0
    var refreshPending = false
    var frameCache: Frame?
    var focusEntryID: String?
    var workStamps: [String: Int] = [:]
    var readStamp: ReadStamp?
    var holdAnchor: (id: String, delta: Double)?
    var copiedFlash: (stepID: String, until: Double)?
    var planStoryOverride: [String: Bool] = [:]
    var holdTicket = 0

    /// What the entries were made from: when none of it changed, a new cursor or hover is a change
    /// of what exists and not of what is said.
    struct ReadStamp: Equatable {
        var reads: Int
        var filter: NeuralStepList.Filter
        var total: Int
        var visible: Int
        var following: Bool
        var outcome: NeuralOutcome
        var answer: Int
    }
    var fonts = BrainListFonts()
    lazy var workFonts = WorkFonts()
    var proseProbe = (line: 24.0, em: 15.0)
    var themeStamp = ""
    var disposed = false
    var realizeCount = 0
    var buildCount = 0
    var solveNanoseconds: UInt64 = 0
    var solves = 0
    var refreshNanoseconds: UInt64 = 0
    var realizeNanoseconds: UInt64 = 0
    var refreshes = 0
    var worstSolve: UInt64 = 0

    static let footerHeight = 32.0
    static let padLeft = 20.0
    static let padRight = 12.0
    static let said12 = 12.0
    static let gap = 20.0
    static let wheelStep = 56.0
    static let scrollEase = 0.075
    static let arrivalDuration = 0.12
    static let justNowDuration = 6.0
    static let storyMax = NeuralStageMetrics.storyMax

    /// Where the account's parts stand in its own coordinates.
    struct Frame {
        var width: Double
        var height: Double
        var header: NeuralRect
        var pins: [(pin: Pin, rect: NeuralRect)]
        var story: NeuralRect
        var footer: NeuralRect?
        var detail: NeuralRect?
        var boxWidth: Double
        var padLeft: Double
        var split: Bool
        var twoColumns: Bool
    }

    init(owner: BrainView) {
        self.owner = owner
        ref = WeakBrainView(owner)
        account = owner.model.account(
            answer: owner.row.answer.isEmpty ? nil : owner.row.answer, prompt: owner.row.prompt)
        let rootHolder = Holder()
        let storyHolder = Holder()
        _ = Gtk.releaseInstalled
        root = tailscode_brain_row_new(
            { width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().account?.solveRoot(
                    width: Int(width), height: Int(height), sink: sink)
            },
            { _, _ in 1 }, Unmanaged.passRetained(rootHolder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })!
        story = tailscode_brain_row_new(
            { width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<Holder>.fromOpaque(raw).takeUnretainedValue().account?.solveStory(
                    width: Int(width), height: Int(height), sink: sink)
            },
            { _, _ in 1 }, Unmanaged.passRetained(storyHolder).toOpaque(),
            { raw in
                guard let raw else { return }
                Unmanaged<Holder>.fromOpaque(raw).release()
            })!
        header = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "bn-ac-head")
        headerBox = BrainUI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12, "bn-ac-head-row")
        gtk_widget_set_hexpand(headerBox, 1)
        gtk_box_append(ptr(header), headerBox)
        let footerHolder = PaintHolder(kind: 0)
        let scrollHolder = PaintHolder(kind: 1)
        footer = Self.paintCanvas(footerHolder)
        pill = gtk_button_new()!
        scrollbar = Self.paintCanvas(scrollHolder)
        rootHolder.account = self
        storyHolder.account = self
        footerHolder.account = self
        scrollHolder.account = self
        build()
    }

    final class Holder: @unchecked Sendable {
        weak var account: BrainAccount?
    }

    func build() {
        Gtk.addClass(root, "bn-account")
        Gtk.addClass(story, "bn-story")
        gtk_widget_set_focusable(story, 1)
        gtk_widget_set_can_focus(story, 1)
        tailscode_set_accessible_label(story, BrainWords.accountLabel)
        gtk_widget_set_can_target(footer, 0)
        gtk_widget_set_can_target(scrollbar, 0)
        tailscode_set_accessible_hidden(footer, 1)
        tailscode_set_accessible_hidden(scrollbar, 1)
        buildPill()
        for part in [header, story, footer, scrollbar, pill] { tailscode_brain_row_add(root, part) }
        installInput()
    }

    func buildPill() {
        Gtk.addClass(pill, "bn-follow")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        BrainUI.add(row, BrainUI.label(BrainWords.followingPaused, "bn-follow-text"), BrainUI.label("End", "bn-follow-key"))
        gtk_button_set_child(ptr(pill), row)
        gtk_widget_set_cursor_from_name(pill, "pointer")
        gtk_widget_set_visible(pill, 0)
        let ref = self.ref
        Gtk.connect(UnsafeMutableRawPointer(pill), "clicked") {
            Gtk.onMain { ref.view?.accountJumpToLatest() }
        }
        tailscode_set_accessible_label(pill, BrainWords.followingPaused)
    }

    /// How many items one frame of the move that opens the account may make, and whether it left
    /// some for the next.
    var makeCap: Int?
    var pendingRealize = false
}
