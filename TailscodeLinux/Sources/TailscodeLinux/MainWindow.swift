import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// The window: the chat list, the tiling tree of conversations, and the project they work in.
///
/// State lives here on the GLib main context; everything that talks to a server happens in a
/// detached `Task` and comes back through ``Gtk/onMain(_:)``. There is no `@MainActor` anywhere in
/// this app — `g_application_run` never drains libdispatch's main queue, so awaiting into a
/// main-actor type from a signal handler would suspend forever with no crash and no log line.
///
/// A conversation itself lives in a ``ChatPane``; this class owns only what is genuinely the
/// window's — the sidebar, the file tree and terminal beside the tree, the shortcut dispatcher,
/// and the dialogs — and reaches the conversation through ``SplitHost``'s focused pane.
final class MainWindow: @unchecked Sendable {
    var window: UnsafeMutablePointer<GtkWidget>?
    var contentHeader: UnsafeMutablePointer<GtkWidget>?
    var studioSheet: StudioSheet?
    let sidebarList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let sidebarBanner = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let titleLabel = Gtk.label("", css: "mono", selectable: false)
    let terminal = TerminalPane()

    let searchEntry = gtk_search_entry_new()!

    var sidebarLimit = 60
    /// Draws of the chat list are spaced by this, so a burst of presence changes, list pushes and
    /// refreshes is one draw and the one that closes it. The row models of the last draw are kept
    /// beside it, and the keys whose model moved since the widgets were last made wait in
    /// `sidebarDirtyKeys` for a draw that can be seen.
    var sidebarCoalescer = RenderCoalescer()
    var sidebarRowCache = SessionRowModelCache()
    var sidebarDirtyKeys: Set<String> = []
    var sidebarTornDown = false
    var pendingListChanges: [(change: SessionListChange, profile: ConnectionProfile)] = []
    var listGatherQueued = false
    /// The first-class way into video, kept so its promise and its mark can be rewritten whenever
    /// a renderer is chosen or a render starts.
    var videoButton: UnsafeMutablePointer<GtkWidget>?
    var videoRing: ForgeButtonRing?
    /// The standing mark. One line in the sidebar's foot, rendered from what this device already
    /// knew before any check of this launch has come back — and hidden outright when there is
    /// nothing standing, because a mark that is always lit stops being read.
    let updateBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    let updateGlyph = Gtk.label("·", css: nil, selectable: false)
    let updateHeadline = Gtk.label("", css: "sidebar-detail", selectable: false)
    let usageBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    /// The world clock, leading the Update chip in the foot's one row. It is always there: unlike
    /// the Update chip it has nothing that could be settled and so nothing to hide.
    lazy var clockChip = ClockChip { [weak self] in
        Gtk.onMain { [weak self] in self?.presentClock() }
    }
    let orb = OrbPainter()
    var agentsEntry: AgentsSidebarEntry?
    var orbTarget: SessionEntry?
    var orbKinds: [ActivityKind?] = []
    var usageTask: Task<Void, Never>?

    var splitWidget: UnsafeMutablePointer<GtkWidget>?
    var terminalPaned: UnsafeMutablePointer<GtkWidget>?
    var sidebarPane: UnsafeMutablePointer<GtkWidget>?
    var sidebarTitle: UnsafeMutablePointer<GtkWidget>?
    /// The name's own width, remembered rather than re-measured: GTK measures a hidden widget as
    /// nothing, so a title taken off for being too wide would measure zero, look like it fits, and
    /// come straight back — the flicker of a header arguing with itself once per frame.
    var sidebarTitleWidth: Int32 = 0
    var lastSidebar: ([String], [String], String, String)?
    /// The rows as last drawn, so a change to one of them redraws that row alone. The sidebar used
    /// to be torn down and rebuilt whenever any row's text moved — an age crossing a minute, a
    /// tool step changing, the row just clicked losing its unread mark — and a click landing on a
    /// list that is being rebuilt under it is a click that never happens.
    var lastVisible: [ChatListItem] = []
    /// A click is a press and a release, and a row rebuilt between the two never becomes one. The
    /// list is held for the length of the press and redrawn on the release, the way the transcript
    /// already is.
    var sidebarPointerHeld = false
    var sidebarRenderHeld = false
    static let sidebarHoldCeiling: UInt32 = 1200

    /// The last full row list per session, shared across every pane so a chat reopened anywhere —
    /// same pane, another pane, a second pane on the same session — paints in the first frame.
    var sessionRows: [String: [TranscriptRow]] = [:]
    var sessionRowOrder: [String] = []

    var entries: [SessionEntry] = []
    /// The configured servers, kept on the main context so an empty pane can ask its question in
    /// the same frame the split happens rather than after a hop through the directory actor.
    var knownProfiles: [ConnectionProfile] = []
    var welcomeTailscale: TailscaleReading?
    var welcomeFixture: FirstRunState?
    var readingTailscaleForWelcome = false
    var mintingPanes: Set<PaneID> = []
    var servers: ServerManager?
    /// Sessions whose delete is confirmed but not yet acknowledged by the server. Every listing
    /// keeps reporting the session until the delete lands, and each report would resurrect the
    /// row; the tombstone outlives them all. Keyed on `(profileID, sessionID)` like every store
    /// here, because a bulk delete spanning two servers meets the same session id twice and a bare
    /// id would take the wrong row off the wrong machine.
    var pendingDeletes: Set<String> = []
    /// The chats marked for a verb, an ephemeral gesture rather than a preference — pruned to what
    /// the list is actually drawing every time it re-renders.
    var marks = ChatSelection()
    var showingArchive = false
    var sidebarScroller: UnsafeMutablePointer<GtkWidget>?
    let rowVerbs = ChatRowVerbStrip()
    var sidebarOverlay: UnsafeMutablePointer<GtkWidget>?
    var sidebarPointer: (x: Double, y: Double)?
    var sidebarVerbRefreshQueued = false
    var sidebarScrollToken: UInt = 0
    var sidebarScrolling = false
    var warmIntentKey: LiveKey?
    var warmIntentToken: UInt = 0
    var sidebarColumn: UnsafeMutablePointer<GtkWidget>?
    var sidebarScrollTarget: Double?
    var sidebarScrollRestore: Double?
    /// The row widgets on screen, in the order they were appended, so the accent can move between
    /// two of them without rebuilding the list around them. Each is held weakly and the array is
    /// emptied before every teardown and when the window is destroyed: a pointer here must never
    /// outlive the row it names.
    var sidebarRows: [SidebarRowWidget] = []
    var sidebarReveal: String?
    var visible: [ChatListItem] = []
    var unreachable: [String] = []
    /// When each server was last heard from, keyed as `unreachable` is. A frozen row's age is read
    /// from here, so a machine that stopped answering stops its clocks instead of ageing a turn.
    var lastHeard: [String: Date] = [:]
    var watchSummary: WatchSummary?
    var watchCheckedAt: Date?
    var watchCheck: Task<Void, Never>?
    var lastQuotas: [(String, UsageQuota)] = []
    /// The last good reading each machine gave for each account, served as cached while a poll
    /// fails and for no longer than ``QuotaFreshness/keptFor``.
    var heldQuotas: [HeldReading] = []
    /// When the last poll actually answered. Nil is a state rather than a missing value: nobody
    /// has come back yet, and the strip says so instead of showing a quiet account.
    var quotasAnsweredAt: Date?
    /// Whether the sidebar is currently wide enough for the strip's bars.
    var usageBarsFit = true
    /// The state the driver pinned the strip to, so every state can be looked at headlessly
    /// without an account that happens to be in it.
    var usageDemo: QuotaGlance?

    /// Quotas the panes read for used-up surfaces — same numbers the sidebar footer shows.
    func quotasForStatus() -> [UsageQuota] { lastQuotas.map(\.1) }
    var cursor = 0
    var filter = ""
    var projectScope: ProjectScope?
    /// The results of the last submitted search, and whether one is in flight. A list that is
    /// looking must say so: silence while a fleet answers is indistinguishable from nothing found.
    var searchBoard: TranscriptSearch.Board?
    var searchRunning = false
    var searchTask: Task<Void, Never>?
    var pendingChords: [KeyChord] = []
    var shortcuts = ShortcutSet.load()
    var focused: Pane = .chats
    /// The chat the person just started from the + button: known-empty, kept in the list by hand
    /// until the server's own listing carries it.
    var freshlyCreated: SessionEntry?
    var refreshTask: Task<Void, Never>?
    var toastOverlay: UnsafeMutablePointer<GtkWidget>?
    var lastFlash: OpaquePointer?
    var demoDial: ModelDialPopover?
    var demoParty: PartyPopover?
    var listStreamTasks: [String: Task<Void, Never>] = [:]
    var lastCatalogWarm: [String: Date] = [:]
    var usageStripSignature = ""

    var splitHost: PaneTiling!
    /// What each restored pane was showing, until the listing carries the session and the pane
    /// can open it for real.
    var pendingBindings: [PaneID: SplitPaneSession] = [:]
    var listedFromNetwork = false
    /// Chats a safe restore left paused after an unclean exit: shown, named, and not streaming
    /// until the person resumes them from the banner or by pressing into the pane.
    var parkedBindings: [PaneID: SplitPaneSession] = [:]
    /// Restored chats whose listing has arrived, waiting their turn in the staggered wake.
    var readyToWake: [PaneID: SessionEntry] = [:]
    var restoreWake = RestoreWake(order: [])
    var wakeScheduled = false
    var restoreBanner: RestoreBanner?
    var liveChipHold: Gtk.WeakWidget?
    var tornDown = false

    /// The live chip, or nil once the toolkit has disposed it: timers and hops read it long after
    /// the window it hangs in may have gone.
    var liveChip: UnsafeMutablePointer<GtkWidget>? { liveChipHold?.widget }

    /// Whether the window is still standing, for the window's own periodic work.
    var isStanding: Bool { !tornDown && !Gtk.isQuitting }
    var liveChipText = ""

    var windowWidget: UnsafeMutablePointer<GtkWidget>? { window }

    var activePane: ChatPane { splitHost.activePane }

    /// The process's live runtime: the window's drain, the one conversation hub and the edge
    /// services every pane and background watch share.
    let live = LiveRuntime()

    /// Conversations a pane moved on from, watched so a turn still in flight keeps its LIVE NOW seat
    /// until it settles and a held queue still drains. Each is a `watching` lease on the hub, keyed
    /// as the sidebar keys a chat.
    var watchLeases: [String: LiveLease] = [:]
    var backgroundPresence: [String: SessionPresence] = [:]
    /// What each conversation's last settled witness said, carried across the moment one watcher
    /// hands a chat to another. Without it, opening a live chat on a server whose listing cannot
    /// report a turn dropped the row to RECENT for one round trip and then took it back.
    var presenceLedger = PresenceLedger()
}

/// A chat row that is on screen: the widget, and the two identities the window needs to find it
/// again — the pin key a reveal names it by, and the bare session id the accent is decided on.
struct SidebarRowWidget {
    let key: String
    /// Every conversation the row stands for: a remembered split wears the accent when any of the
    /// chats inside it is the one on screen.
    let sessionIDs: [String]
    private let holder: Gtk.WeakWidget

    init(key: String, sessionIDs: [String], widget: UnsafeMutablePointer<GtkWidget>) {
        self.key = key
        self.sessionIDs = sessionIDs
        holder = Gtk.WeakWidget(widget)
    }

    /// The row's widget, or nil once GTK has disposed of it.
    var widget: UnsafeMutablePointer<GtkWidget>? { holder.widget }
}

