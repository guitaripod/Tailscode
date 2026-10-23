import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// One turn's brain in the transcript: a card while it is collapsed, and the stage with its
/// readout and footer while it is open, and the move that carries one into the other.
///
/// The row's widget is kept for the life of the turn. A step arriving, a tool ending or a theme
/// change is a new row value the pane hands to `restate`, which brings the model up to date and
/// redraws what changed; opening and closing is a move between two arrangements of the same
/// children. Every child is placed by rectangles Core's `NeuralStageMetrics` computes for the
/// row's width, at the moment the row is allocated, so a rect is never a frame late and a
/// resize between breakpoints rebuilds nothing.
///
/// The view lives on its root widget's own data, so a row torn down releases the stage, the
/// compositor and the clock without anyone remembering to.
final class BrainView: @unchecked Sendable {
    static let key = "tailscode-brain-view"

    enum Phase: Sendable {
        case closed
        case open
        case moving
    }

    let widget: UnsafeMutablePointer<GtkWidget>
    weak var host: BrainHost?
    let turnID: String
    var row: BrainRow
    var model: NeuralBrainModel
    var inks: BrainInks
    var phase = Phase.closed
    var card: BrainCard!
    var stage: BrainStage?
    var readout: BrainReadout?
    var list: BrainList?
    var filters: BrainFilters?
    var account: BrainAccount?
    var readoutClip: UnsafeMutablePointer<GtkWidget>?
    var wordmark: UnsafeMutablePointer<GtkWidget>?
    var dimmedNodes: Set<String> = []
    var legendPopover: Gtk.WeakWidget?
    var pendingHover: (id: String?, delay: Double)?
    var hoverApplied: String?
    var hoverFlushScheduled = false
    var lastHoverApply = 0.0
    var menuPopover: Gtk.WeakWidget?
    var footer: BrainFooter?
    var moveCanvas: UnsafeMutablePointer<GtkWidget>?
    var edgeCanvas: UnsafeMutablePointer<GtkWidget>?
    lazy var clock = BrainClock { [weak self] time in self?.step(time) }
    var isSuspended = false
    var context: TranscriptContext?
    var replayWhenOpen = false
    var announcement: String?

    var metricsMemo:
        (width: Double, density: ChatDensity, zones: Int, viewport: Int, need: Double, value: NeuralStageMetrics)?
    var lastWidth = 0.0
    var lastDensity = ChatDensity.comfortable
    var scaleFactor = 1

    var moveState: BrainMove?
    var pendingOpen: PendingOpen?
    var openSchedule: NeuralOpenSchedule?
    var movedFrames = 0
    var revealOverride: BrainMove.Reveal?

    var readoutTicket = 0
    var leaderState = BrainLeaderState()
    var contentFade: Double?
    var contentFadeStart = 0.0
    var prefetched: NeuralCompositor?
    var prefetchTicket = 0
    var readoutHeld = false
    var needsDraw = false
    var visibleCache: (time: Double, value: Bool)?
    var tokenComputations = 0
    var tickCosts: [String: UInt64] = [:]
    var tickCount = 0
    var lastFooterSync = 0.0
    var lastReadoutTick = 0.0
    var tokenMemo: (answer: String, revision: Int, tokens: [String])?
    var frozen = false
    var readoutFadingUntil = 0.0
    var stageFocused = false
    var disposed = false

    struct PendingOpen {
        let started: Double
        let swapped: Bool
    }

    var isOpen: Bool { row.open }
    var hasStage: Bool { stage != nil }

    /// Whether this brain may build its stage: always when the person opened it, and otherwise
    /// only while the governor allows a head to be drawn. A shed window refuses to open the latest
    /// turn by itself; it never refuses a press.
    var stageMayOpen: Bool { BrainBudget.stageAllowed || (host?.choices[turnID] != nil) }
    /// A harness keeps the first picture from being ready, which is the renderer being too slow:
    /// the open then falls back to taking the stage with no move.
    var holdPictureForTest = false
    /// How long an open waits for the head's first picture before taking the stage with no move.
    nonisolated(unsafe) static var openFallbackMilliseconds: UInt32 = 1800
    var isClockRunning: Bool { clock.isRunning }

    static func current(of widget: UnsafeMutablePointer<GtkWidget>) -> BrainView? {
        guard let raw = g_object_get_data(ptr(widget), key) else { return nil }
        return Unmanaged<BrainView>.fromOpaque(raw).takeUnretainedValue()
    }

    static func make(_ row: BrainRow, context: TranscriptContext) -> UnsafeMutablePointer<GtkWidget> {
        let view = BrainView(row: row, context: context)
        let box = Unmanaged.passRetained(view).toOpaque()
        g_object_set_data_full(
            ptr(view.widget), key, box,
            { raw in
                guard let raw else { return }
                let view = Unmanaged<BrainView>.fromOpaque(raw).takeRetainedValue()
                view.teardown()
            })
        view.finishBuilding()
        return view.widget
    }

    final class RowHost: @unchecked Sendable {
        weak var view: BrainView?
    }

    init(row: BrainRow, context: TranscriptContext) {
        self.row = row
        self.context = context
        host = context.brains
        turnID = row.id
        let brainContext = context.brains?.context(for: row.id) ?? .none
        model = NeuralBrainModel(turn: row.turn, context: brainContext)
        inks = BrainInks(palette: MatrixTheme.palette, face: model.face)
        let holder = RowHost()
        _ = Gtk.releaseInstalled
        widget = tailscode_brain_row_new(
            { width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<RowHost>.fromOpaque(raw).takeUnretainedValue().view?.solve(
                    width: Int(width), height: Int(height), sink: sink)
            },
            { width, raw in
                guard let raw else { return 1 }
                return Int32(
                    Unmanaged<RowHost>.fromOpaque(raw).takeUnretainedValue().view?.height(
                        forWidth: Int(width)) ?? 1)
            }, Unmanaged.passRetained(holder).toOpaque(),
            { raw in
                guard let raw else { return }
                let holder = Unmanaged<RowHost>.fromOpaque(raw)
                holder.takeUnretainedValue().view?.markDisposed()
                holder.release()
            })!
        holder.view = self
        Gtk.addClass(widget, "brain-row")
        card = BrainCard(owner: self)
    }

    func finishBuilding() {
        for part in card.widgets { tailscode_brain_row_add(widget, part) }
        gtk_widget_set_cursor_from_name(widget, "pointer")
        Gtk.onRelease(widget) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.cardPressed()
            }
        }
        Gtk.onKey(widget) { [weak self] keyval, state in
            self?.cardKey(keyval: keyval, state: state) ?? false
        }
        Gtk.onPointer(
            widget,
            move: { [weak self] _, _ in self?.pointerOverRow(true) },
            leave: { [weak self] in self?.pointerOverRow(false) })
        let focus = Unmanaged.passRetained(FocusWatch { [weak self] entered in
            self?.frameFocus(entered)
        }).toOpaque()
        _ = Gtk.releaseInstalled
        tailscode_on_focus_change(
            widget,
            { raw in
                guard let raw else { return }
                Unmanaged<FocusWatch>.fromOpaque(raw).takeUnretainedValue().handler(true)
            },
            { raw in
                guard let raw else { return }
                Unmanaged<FocusWatch>.fromOpaque(raw).takeUnretainedValue().handler(false)
            }, focus)
        host?.register(self)
        RepeatingMotion.watch(widget) { [weak self] in self?.motionChanged() }
        gtk_widget_set_focusable(widget, 1)
        gtk_widget_set_can_focus(widget, 1)
        card.refresh()
        if row.open, stageMayOpen, NeuralAssetFiles.isAvailable {
            showStage()
        } else {
            setPhase(.closed)
        }
        updateClock()
    }

    final class FocusWatch: @unchecked Sendable {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }

    func teardown() {
        clock.stop()
        stage?.teardown()
        stage = nil
        host?.forget(self)
        readoutTicket += 1
        prefetchTicket += 1
        if let held = prefetched {
            BrainCompositors.release(held)
            prefetched = nil
        }
    }

    deinit { teardown() }

    /// The row's widget is being disposed: its children are about to be unparented and freed, so
    /// nothing a posted hop or a timer does from here on may touch a part of it. Called by the
    /// row itself before it lets go of any child, which is the one moment the parts are still real.
    func markDisposed() {
        disposed = true
        dropPopovers()
        teardown()
        account?.teardown()
        account = nil
        readout = nil
        list = nil
        filters = nil
        readoutClip = nil
        footer = nil
        moveCanvas = nil
        edgeCanvas = nil
        moveState = nil
    }

    /// Whether a part of the stage may still be measured or drawn: the row is alive and sits in a
    /// window.
    func isLive(_ part: UnsafeMutablePointer<GtkWidget>) -> Bool {
        !disposed && gtk_widget_get_root(part) != nil
    }

    // MARK: metrics and layout

    var density: ChatDensity { Preferences.chatDensity }
}
