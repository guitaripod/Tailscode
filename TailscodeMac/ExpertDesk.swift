import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// Every machine's experts as one reading for the whole app, so the sidebar's place, the Experts
/// window, a chat's header and the chooser never disagree about an expert. Read with the machine
/// desk's slow beat, at once when the servers change, after every press that changes an expert,
/// and every ten seconds while some surface that shows experts is on screen — a task starting or a
/// guard turning red is something a person watching should see without asking.
@MainActor
final class ExpertDesk {
    static let shared = ExpertDesk()
    static let didChange = Notification.Name("tailscode.mac.expertDesk.didChange")

    private(set) var board = ExpertBoard.empty
    private(set) var loadedOnce = false
    private var beat: Timer?
    private var fastBeat: Timer?
    private var watchers: Set<ObjectIdentifier> = []
    private var loading = false
    private var askedAgain = false
    private var announcedAt = Date.distantPast

    /// The machines the machine desk reads, so a staged demo stands in for the fleet here too.
    func servers() -> [(profile: ConnectionProfile, backend: any CodingAgentBackend)] {
        MachineDesk.shared.servers()
    }

    func profile(_ id: String) -> ConnectionProfile? {
        servers().first { $0.profile.id == id }?.profile
            ?? ServerDirectory.shared.profiles.first { $0.id == id }
    }

    func backend(for profileID: String) -> (any CodingAgentBackend)? {
        servers().first { $0.profile.id == profileID }?.backend
    }

    func keeping(for profileID: String) -> (any MachineExperts)? {
        backend(for: profileID) as? any MachineExperts
    }

    /// Whether this machine keeps experts: it answered with its list, or its status said so.
    func keepsExperts(_ profileID: String) -> Bool {
        if board.machines.contains(where: { $0.profileID == profileID }) { return true }
        guard let backend = backend(for: profileID) else { return false }
        return backend.capabilities.supportsExperts && backend is any MachineExperts
    }

    var anyKeepsExperts: Bool {
        board.keepsExperts || servers().contains { keepsExperts($0.profile.id) }
    }

    /// The machines an expert can be made on, in the person's order: every machine that keeps
    /// experts except one that did not answer, which cannot take one now.
    var makers: [ConnectionProfile] {
        servers().map(\.profile).filter { profile in
            !board.unanswered.contains { $0.profileID == profile.id } && keepsExperts(profile.id)
        }
    }

    /// The machines that keep experts and did not answer the last read, named the way the app
    /// names a machine that is not answering.
    var silentLine: String? {
        guard !board.unanswered.isEmpty else { return nil }
        return ExpertWords.notAnswering(board.unanswered.map(\.machine).joined(separator: ", "))
    }

    func row(profileID: String, expertID: String) -> ExpertRow? {
        board.row(profileID: profileID, expertID: expertID)
    }

    func row(id: String) -> ExpertRow? {
        board.rows.first { $0.id == id || $0.expert.id == id }
    }

    /// The expert a conversation is a task of, when its machine keeps one by that id.
    func row(for entry: SessionEntry) -> ExpertRow? {
        board.expert(for: entry.session, profileID: entry.profileID)
    }

    /// The demo machine in place of the real ones, for `--open` and the selftest.
    func stageDemo() {
        MachineDesk.shared.stageDemo()
        board = .empty
    }

    func start() {
        guard beat == nil else { return }
        NotificationCenter.default.addObserver(
            forName: ServerDirectory.didChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ExpertDesk.shared.refreshSoon() }
        }
        beat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ExpertDesk.shared.refreshSoon() }
        }
        refreshSoon()
    }

    /// A surface that shows experts is on screen; the desk reads every ten seconds until the last
    /// such surface goes.
    func watch(_ owner: AnyObject) {
        watchers.insert(ObjectIdentifier(owner))
        guard fastBeat == nil else { return }
        fastBeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { ExpertDesk.shared.refreshSoon() }
        }
        refreshSoon()
    }

    func unwatch(_ owner: AnyObject) {
        watchers.remove(ObjectIdentifier(owner))
        guard watchers.isEmpty else { return }
        fastBeat?.invalidate()
        fastBeat = nil
    }

    func refreshSoon() {
        Task { await refresh() }
    }

    /// Every machine asked at once; a read asked for while one is out runs once more after it, so
    /// a press is never answered by a list read before it landed. A read that found nothing new
    /// tells nobody, except once a minute, when lines that count time ("for 3m") move on.
    func refresh() async {
        guard !loading else {
            askedAgain = true
            return
        }
        loading = true
        repeat {
            askedAgain = false
            let fresh = await ExpertBoard.load(servers())
            let changed = !loadedOnce || fresh != board
            board = fresh
            loadedOnce = true
            if changed || Date().timeIntervalSince(announcedAt) >= 55 { announce() }
        } while askedAgain
        loading = false
    }

    /// What a press on the machine answered, put on the shelf before the next read.
    func adopt(_ expert: MachineExpert, profileID: String) {
        var rows = board.rows
        if let index = rows.firstIndex(where: { $0.profileID == profileID && $0.expert.id == expert.id }) {
            rows[index] = ExpertRow(profileID: profileID, machine: rows[index].machine, expert: expert)
        } else {
            let machine = profile(profileID)?.name ?? ""
            rows.append(ExpertRow(profileID: profileID, machine: machine, expert: expert))
        }
        var machines = board.machines
        if !machines.contains(where: { $0.profileID == profileID }) {
            machines.append((profileID, profile(profileID)?.name ?? ""))
        }
        let fresh = ExpertBoard(
            rows: rows, machines: machines, unanswered: board.unanswered.filter { $0.profileID != profileID })
        guard fresh != board else { return }
        board = fresh
        announce()
    }

    func forget(profileID: String, expertID: String) {
        board = ExpertBoard(
            rows: board.rows.filter { !($0.profileID == profileID && $0.expert.id == expertID) },
            machines: board.machines, unanswered: board.unanswered)
        announce()
    }

    /// The name a model string is said by on its machine.
    func modelWord(_ raw: String?, profileID: String) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let catalog = ModelCatalogStore.cached(profileID)
        if let slash = raw.firstIndex(of: "/"), slash != raw.startIndex {
            let selection = ModelSelection(
                providerID: String(raw[..<slash]), modelID: String(raw[raw.index(after: slash)...]))
            return ModelBadge.word(for: selection, in: catalog)
        }
        return ModelBadge.chip(model: raw, effort: nil, providerID: nil, catalog: catalog)?.name ?? raw
    }

    private func announce() {
        announcedAt = Date()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// The colours a line about an expert wears, one tone to one colour wherever an expert is drawn.
@MainActor
enum ExpertInk {
    static func color(_ tone: ExpertTone) -> NSColor {
        switch tone {
        case .quiet: return MacTheme.Color.secondaryLabel
        case .active: return MacTheme.Color.accent
        case .attention: return MacTheme.Color.warning
        case .failing: return MacTheme.Color.danger
        case .good: return MacTheme.Color.success
        }
    }

    /// An expert's hue for the appearance it is drawn in: the brighter value on a dark ground.
    static func hue(_ hue: ExpertHue) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = dark ? hue.rgb.dark : hue.rgb.light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }

    /// A lamp: a dot in the tone's colour, the way a bench item says what the machine found.
    static func lamp(_ tone: ExpertTone, filled: Bool = true) -> NSView {
        let view = LampView(color: color(tone), filled: filled)
        return view
    }
}

/// A small round lamp, drawn rather than typed so it sits on the text's middle at any type size.
@MainActor
final class LampView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var filled: Bool { didSet { needsDisplay = true } }

    init(color: NSColor, filled: Bool) {
        self.color = color
        self.filled = filled
        super.init(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 9), heightAnchor.constraint(equalToConstant: 9),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 9, height: 9) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        if filled {
            color.setFill()
            path.fill()
        } else {
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
