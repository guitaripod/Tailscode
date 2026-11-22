import CodingAgentKit
import Foundation

/// Why there is no terminal to show, in words that say what would change it.
public enum TerminalUnavailable: Sendable, Equatable {
    /// This copy of the app was built without the terminal engine.
    case noEngine
    /// The server is a kind that holds no shells.
    case serverHoldsNone(server: String)
    /// The server's bridge is older than the terminal.
    case serverTooOld(server: String)

    public var words: String {
        switch self {
        case .noEngine:
            return Localized.text("This build of Tailscode was made without its terminal.")
        case .serverHoldsNone(let server):
            return Localized.text(
                "%@ does not hold a terminal. A shell opens beside a chat on a claude-bridge or omp-bridge server.",
                server)
        case .serverTooOld(let server):
            return Localized.text(
                "%@ is running a bridge from before the terminal. Update it and a shell opens here.", server)
        }
    }
}

/// What a terminal is and where it is, for the chrome around it.
public struct TerminalReading: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case opening
        case live
        /// The connection dropped and is being asked for again. The shell is still running.
        case reconnecting
        case ended(code: Int?)
        case unavailable(TerminalUnavailable)
        case failed(String)
    }

    public var phase: Phase
    public var server: String
    public var shell: String?
    public var directory: String?
    public var job: String?
    public var title: String?

    /// One line that says what the pane is: the program in front, where it stands and on which
    /// machine, or what is keeping it from being a terminal.
    public var caption: String {
        switch phase {
        case .opening:
            return Localized.text("Opening a shell on %@…", server)
        case .reconnecting:
            return Localized.text("Reconnecting to %@… the shell is still running", server)
        case .ended(let code):
            guard let code, code != 0 else {
                return Localized.text("The shell ended · Return starts a new one")
            }
            return Localized.text("The shell ended (exit %@) · Return starts a new one", String(code))
        case .unavailable(let reason):
            return reason.words
        case .failed(let message):
            return message
        case .live:
            let front = job ?? shell ?? Localized.text("shell")
            guard let directory else { return Localized.text("%@ on %@", front, server) }
            return Localized.text("%@ · %@ on %@", front, TerminalFollow.shortened(directory), server)
        }
    }

    /// Whether keys go anywhere.
    public var acceptsInput: Bool {
        switch phase {
        case .live, .reconnecting: return true
        default: return false
        }
    }
}

/// How a shell is walked to the folder a conversation works in.
public enum TerminalFollow {
    /// The line that takes a shell standing in `standing` to `wanted`, or nil when the shell is
    /// to be left alone: it is already there, or a program is in front of it and the line would
    /// be typed into that program. The leading space keeps it out of the shell's history where
    /// the shell is set up to honour one.
    public static func line(to wanted: String?, standing: String?, job: String?) -> String? {
        guard let wanted, !wanted.isEmpty, job == nil else { return nil }
        if let standing, trimmed(standing) == trimmed(wanted) { return nil }
        return " cd -- '" + wanted.replacingOccurrences(of: "'", with: "'\\''") + "'\r"
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// A path as a prompt writes it. The home folder is the server's, which a client cannot
    /// read, so it is recognised by shape: `/home/name` and `/Users/name`.
    public static func shortened(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "home" || parts[0] == "Users" else { return path }
        return parts.count == 2 ? "~" : "~/" + parts.dropFirst(2).joined(separator: "/")
    }
}

/// The name a client gives its terminal on a server, so that after it has been closed and opened
/// it finds the shell it left: one per desk and kind of client.
public enum TerminalDeskName {
    public static func current(client: String) -> String {
        "\(ProcessInfo.processInfo.hostName) (\(client))"
    }
}

/// One terminal as a client holds it: a shell on a server, and the screen it draws on here.
///
/// The session finds the shell this desk left on the server, or opens one, and from then on keeps
/// the two ends agreeing: the shell's bytes are drawn as they arrive on a thread that is not the
/// interface's, whatever the terminal owes the shell in answer is sent back, a connection that
/// drops is picked up at the byte it reached, a shell the server no longer holds is replaced by a
/// fresh one in the same folder with a line that says so, and one that ended waits for Return.
///
/// It is not bound to any thread. `onChange` and `onDirty` are called from wherever the news
/// arrived; a client hops to its own thread before touching a widget.
public final class TerminalSession: @unchecked Sendable {
    public struct Target: Sendable, Equatable {
        public var server: String
        public var directory: String?
        public var sessionID: String?

        public init(server: String, directory: String?, sessionID: String? = nil) {
            self.server = server
            self.directory = directory
            self.sessionID = sessionID
        }
    }

    public let screen: TerminalScreen?

    private let backend: any CodingAgentBackend
    private let desk: String
    private let lock = NSLock()
    private var target: Target
    private var phase: TerminalReading.Phase = .opening
    private var info: TerminalInfo?
    private var link: TerminalLink?
    private var pump: Task<Void, Never>?
    private var cols: Int
    private var rows: Int
    private var dirtyPosted = false
    private var started = false
    private var stopped = false
    private var replaced = 0
    private var continuing: String?
    private var measured = TerminalTimings()
    private var echo = PredictiveEcho()
    private var drawnRow: Int?
    private var changeHandler: (@Sendable () -> Void)?
    private var dirtyHandler: (@Sendable () -> Void)?
    private let outbox: AsyncStream<Outgoing>.Continuation
    private let courier: Task<Void, Never>

    public init(
        backend: any CodingAgentBackend, target: Target, desk: String, colors: TerminalColors,
        cols: Int = 80, rows: Int = 24
    ) {
        self.backend = backend
        self.target = target
        self.desk = desk
        self.cols = cols
        self.rows = rows
        self.screen = TerminalScreen(cols: cols, rows: rows)
        screen?.apply(colors)
        let (stream, outbox) = AsyncStream<Outgoing>.makeStream()
        self.outbox = outbox
        let carrier = Carrier()
        self.carrier = carrier
        courier = Task {
            for await item in stream {
                guard let link = carrier.link else { continue }
                switch item {
                case .bytes(let bytes): await link.send(bytes)
                case .size(let cols, let rows): await link.resize(cols: cols, rows: rows)
                }
            }
        }
    }

    private enum Outgoing: Sendable {
        case bytes(Data)
        case size(cols: Int, rows: Int)
    }

    deinit {
        pump?.cancel()
        courier.cancel()
        outbox.finish()
    }

    /// The link keys and sizes are carried to. They leave through one queue in the order they
    /// happened, whichever thread they happened on, and are dropped while there is no shell to
    /// hear them.
    private final class Carrier: @unchecked Sendable {
        private let lock = NSLock()
        private var held: TerminalLink?

        var link: TerminalLink? {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    private let carrier: Carrier

    /// Called when the reading changes: the phase, the folder, the program in front.
    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { changeHandler = handler }
    }

    /// Called when there is something new to draw, once, until the next frame is taken.
    public func onDirty(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { dirtyHandler = handler }
    }

    public var reading: TerminalReading {
        lock.withLock {
            TerminalReading(
                phase: phase, server: target.server, shell: info?.shell, directory: info?.directory,
                job: info?.job, title: screen?.title)
        }
    }

    /// How long the shell kept this device waiting, for the log.
    public var timings: TerminalTimings { lock.withLock { measured } }

    /// The server's own name for this terminal, once there is one.
    public var terminalID: String? { lock.withLock { info?.id } }

    public func start() {
        let begin: Bool = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard begin else { return }
        guard screen != nil else {
            set(.unavailable(.noEngine))
            return
        }
        pump = Task { [weak self] in await self?.open(adopting: true) }
    }

    private func set(_ phase: TerminalReading.Phase) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard self.phase != phase else { return nil }
            self.phase = phase
            return changeHandler
        }
        handler?()
    }

    private func markDirty() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !dirtyPosted else { return nil }
            dirtyPosted = true
            return dirtyHandler
        }
        handler?()
    }

    /// The frame to draw now. Taking it is what lets the next change announce itself.
    public func frame(force: Bool = false) -> TerminalFrame? {
        let (guesses, stale): ([UInt8], Int?) = lock.withLock {
            dirtyPosted = false
            echo.expire(at: Date())
            return (echo.shown, drawnRow)
        }
        guard let frame = screen?.frame(force: force) else { return nil }
        guard let drawn = frame.drawn(over: guesses, stale: stale) else {
            lock.withLock { drawnRow = nil }
            return frame
        }
        lock.withLock { drawnRow = drawn.row }
        if drawn.row != nil { markDirtyLater() }
        return drawn.frame
    }

    /// A frame drawn over is asked for again once its guesses may have expired, so a guess the
    /// shell never answered does not stay on screen.
    private func markDirtyLater() {
        DispatchQueue.global().asyncAfter(deadline: .now() + PredictiveEcho.patience + 0.1) { [weak self] in
            self?.markDirty()
        }
    }

    private func hosting() async -> (any TerminalHostingBackend)? {
        guard let hosting = backend as? any TerminalHostingBackend else {
            set(.unavailable(.serverHoldsNone(server: target.server)))
            return nil
        }
        if !backend.capabilities.supportsTerminals { _ = try? await backend.health() }
        guard backend.capabilities.supportsTerminals else {
            let bridge = backend.agentType == .claudeCode || backend.agentType == .omp
            set(.unavailable(bridge ? .serverTooOld(server: target.server) : .serverHoldsNone(server: target.server)))
            return nil
        }
        return hosting
    }

    /// Finds the shell this desk left on the server, or starts one, and reads it until it ends.
    private func open(adopting: Bool) async {
        guard let hosting = await hosting() else { return }
        lock.withLock { measured.asked(at: Date()) }
        set(.opening)
        let (wanted, size) = lock.withLock { (target, (cols, rows)) }
        do {
            var found: TerminalInfo?
            if adopting {
                found = try await hosting.terminals().first { $0.desk == desk && $0.isRunning }
            }
            let terminal: TerminalInfo
            if let found {
                terminal = found
            } else {
                terminal = try await hosting.openTerminal(
                    TerminalOpenRequest(
                        directory: wanted.directory, session: wanted.sessionID, desk: desk,
                        cols: size.0, rows: size.1))
            }
            await read(terminal, on: hosting)
        } catch {
            guard !Task.isCancelled else { return }
            set(.failed(Self.words(for: error, server: wanted.server)))
        }
    }

    private static func words(for error: Error, server: String) -> String {
        if case AgentError.http(_, let body) = error,
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["error"] as? String, !message.isEmpty
        {
            return message
        }
        return Localized.text("%@ did not open a shell. It will be asked again when you press Return.", server)
    }

    private func read(_ terminal: TerminalInfo, on hosting: any TerminalHostingBackend) async {
        let link = TerminalLink(backend: hosting, id: terminal.id)
        let size: (Int, Int) = lock.withLock {
            info = terminal
            self.link = link
            return (cols, rows)
        }
        carrier.link = link
        await link.start()
        await link.resize(cols: size.0, rows: size.1)
        for await event in link.events {
            switch event {
            case .output(let bytes):
                lock.withLock {
                    measured.bytesArrived(at: Date())
                    echo.heard(bytes)
                }
                guard let replies = screen?.feed(bytes) else { continue }
                if !replies.isEmpty { await link.send(replies) }
                markDirty()
            case .reset:
                lock.withLock { echo.forget() }
                if let note = lock.withLock({ () -> String? in defer { continuing = nil }; return continuing }) {
                    screen?.feed(Data(("\u{1b}[?1049l\u{1b}[!p\u{1b}[0m" + note).utf8))
                } else {
                    screen?.reset()
                }
                let size = lock.withLock { (cols, rows) }
                await link.resize(cols: size.0, rows: size.1)
                markDirty()
            case .state(let state):
                let handler: (@Sendable () -> Void)? = lock.withLock {
                    let changed =
                        info?.directory != state.directory || info?.job != state.job
                        || info?.shell != state.shell
                    info = state
                    return changed ? changeHandler : nil
                }
                handler?()
            case .connection(let connection):
                switch connection {
                case .live: set(.live)
                case .waiting: set(.reconnecting)
                case .connecting: break
                }
            case .ended(let code):
                screen?.feed(Data(Self.note(Localized.text("The shell ended. Press Return for a new one.")).utf8))
                markDirty()
                drop()
                set(.ended(code: code))
                return
            case .gone:
                drop()
                await replace()
                return
            }
        }
    }

    private func drop() {
        lock.withLock { link = nil }
        carrier.link = nil
    }

    /// A line of the app's own among the shell's, set apart so it is not mistaken for output.
    static func note(_ text: String) -> String {
        "\r\n\u{1b}[0;2;3m" + text + "\u{1b}[0m\r\n"
    }

    /// The server no longer holds the shell: it restarted, or the terminal was closed from
    /// somewhere else. A fresh one is opened where the old one stood, once; a server that cannot
    /// keep one open is not asked in a loop.
    private func replace() async {
        let (stopped, attempts, standing) = lock.withLock { () -> (Bool, Int, String?) in
            replaced += 1
            return (self.stopped, replaced, info?.directory)
        }
        guard !stopped, !Task.isCancelled else { return }
        guard attempts <= 3 else {
            set(.failed(Localized.text("%@ keeps closing this terminal. Press Return to ask again.", target.server)))
            return
        }
        lock.withLock {
            if let standing { target.directory = standing }
            continuing = Self.note(
                Localized.text("%@ restarted. This is a new shell in the same folder.", target.server))
        }
        await open(adopting: false)
    }

    /// Starts a new shell where the last one stood, after one ended or could not be opened.
    public func startOver() {
        let again: Bool = lock.withLock {
            switch phase {
            case .ended, .failed:
                replaced = 0
                continuing = ""
                if let standing = info?.directory { target.directory = standing }
                return !stopped
            default:
                return false
            }
        }
        guard again else { return }
        pump?.cancel()
        pump = Task { [weak self] in await self?.open(adopting: false) }
    }

    /// Bytes for the shell, already in the form it reads.
    public func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.withLock { echo.forget() }
        transmit(bytes)
    }

    private func transmit(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.withLock { measured.keyLeft(at: Date()) }
        outbox.yield(.bytes(bytes))
    }

    /// A key. Typing snaps a scrolled-back screen to the newest line, and Return on a shell that
    /// has ended starts a new one.
    public func press(_ press: TerminalKeyPress) {
        let phase = lock.withLock { self.phase }
        switch phase {
        case .ended, .failed:
            if press.key == .enter || press.key == .numpadEnter { startOver() }
            return
        default:
            break
        }
        guard let screen else { return }
        let bytes = screen.bytes(for: press)
        guard !bytes.isEmpty else { return }
        screen.scrollToBottom()
        send(bytes)
        markDirty()
    }

    /// Text a keyboard settled on: a letter, a composed character, a word from an input method.
    public func type(_ text: String) {
        guard let screen, !text.isEmpty else { return }
        let phase = lock.withLock { self.phase }
        switch phase {
        case .ended, .failed:
            if text == "\r" || text == "\n" { startOver() }
            return
        default:
            break
        }
        screen.scrollToBottom()
        lock.withLock { echo.typed(text, at: Date()) }
        transmit(Data(text.utf8))
        markDirty()
    }

    /// Text that was not typed: a paste, a dictation, a drop.
    public func paste(_ text: String) {
        guard let screen, !text.isEmpty else { return }
        screen.scrollToBottom()
        send(screen.bytes(pasting: text))
        markDirty()
    }

    public func focus(_ focused: Bool) {
        guard let screen else { return }
        send(screen.bytes(focused: focused))
    }

    /// The size the pane can show. The screen takes it at once; the server is told the last size
    /// of a drag, not every one.
    public func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let size = TerminalSize.clamped(cols: cols, rows: rows)
        let changed: Bool = lock.withLock {
            defer {
                self.cols = size.cols
                self.rows = size.rows
            }
            return self.cols != size.cols || self.rows != size.rows
        }
        screen?.resize(cols: size.cols, rows: size.rows, cellWidth: cellWidth, cellHeight: cellHeight)
        guard changed else { return }
        outbox.yield(.size(cols: size.cols, rows: size.rows))
        markDirty()
    }

    /// Walks the shell to the folder the conversation in focus works in, when that is somewhere
    /// else and the shell is at its prompt to be told.
    public func follow(directory: String?) {
        let line: String? = lock.withLock {
            target.directory = directory ?? target.directory
            guard case .live = phase, let info else { return nil }
            return TerminalFollow.line(to: directory, standing: info.directory, job: info.job)
        }
        if let line { send(Data(line.utf8)) }
    }

    /// The folder the shell stands in, as the server last read it.
    public var standingDirectory: String? {
        lock.withLock {
            guard case .live = phase else { return nil }
            return info?.directory
        }
    }

    /// Lets go of the terminal and leaves the shell running on its server for this desk to find.
    public func leave() {
        let link: TerminalLink? = lock.withLock {
            stopped = true
            defer { self.link = nil }
            return self.link
        }
        carrier.link = nil
        pump?.cancel()
        if let link { Task { await link.detach() } }
    }

    /// Ends the shell on its server.
    public func end() {
        let link: TerminalLink? = lock.withLock {
            stopped = true
            defer { self.link = nil }
            return self.link
        }
        carrier.link = nil
        pump?.cancel()
        if let link { Task { await link.close() } }
    }
}
