import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore
import UIKit

/// Every machine's experts, read together for Home's shelf, the iPad's sidebar, the chooser and
/// every expert screen. Read on Home's refresh, after any change made here, and every ten seconds
/// while a screen about an expert is on screen — never on a clock while nobody is looking.
@MainActor
final class ExpertDesk {
    static let shared = ExpertDesk()
    static let didChange = Notification.Name("tailscode.expertDesk.didChange")

    private(set) var board = ExpertBoard.empty
    private(set) var hasLoaded = false
    private var loadedAt: Date?
    private var loading: Task<Void, Never>?
    private var watchers = 0
    private var ticker: Task<Void, Never>?
    private var heldDebriefs: Set<String> = []

    private init() {}

    func backend(forProfileID id: String) -> (any CodingAgentBackend)? {
        MachineDesk.shared.backend(forProfileID: id)
    }

    func experts(forProfileID id: String) -> (any MachineExperts)? {
        backend(forProfileID: id) as? any MachineExperts
    }

    func profile(_ id: String) -> ConnectionProfile? { MachineDesk.shared.profile(id) }

    func row(profileID: String, expertID: String) -> ExpertRow? {
        board.row(profileID: profileID, expertID: expertID)
    }

    func row(for session: AgentSession, profileID: String) -> ExpertRow? {
        board.expert(for: session, profileID: profileID)
    }

    /// Reads every machine again, or joins the read already going. Answers the read, so a pull to
    /// refresh can end its spinner when the read ends whether or not anything changed; nil when a
    /// read this recent is kept.
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never>? {
        if let loading { return loading }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 10 { return nil }
        let read = Task { [weak self] in
            guard let self else { return }
            let servers = ConnectionController.shared.profiles.compactMap { profile in
                MachineDesk.shared.backend(for: profile).map { (profile: profile, backend: $0) }
            }
            let board = await ExpertBoard.load(servers)
            let changed = board != self.board || !self.hasLoaded
            self.board = board
            self.hasLoaded = true
            self.loadedAt = Date()
            self.loading = nil
            guard changed else { return }
            MidgarLog.info(
                "expert desk: \(board.rows.count) experts on \(board.machines.count) machines, \(board.pending) notes waiting",
                category: .session)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        loading = read
        return read
    }

    /// Puts what a machine just answered about one expert on the board at once, so the screen
    /// that pressed something shows its answer before the next read.
    func adopt(_ expert: MachineExpert, profileID: String) {
        var rows = board.rows
        if let index = rows.firstIndex(where: { $0.profileID == profileID && $0.expert.id == expert.id }) {
            rows[index] = ExpertRow(profileID: profileID, machine: rows[index].machine, expert: expert)
        } else {
            let machine = profile(profileID)?.name ?? ""
            rows.append(ExpertRow(profileID: profileID, machine: machine, expert: expert))
        }
        board = ExpertBoard(rows: rows, machines: board.machines, unanswered: board.unanswered)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func forget(profileID: String, expertID: String) {
        board = ExpertBoard(
            rows: board.rows.filter { !($0.profileID == profileID && $0.expert.id == expertID) },
            machines: board.machines, unanswered: board.unanswered)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// A screen about an expert is on screen: keep the board fresh while it is.
    func watch() {
        watchers += 1
        refresh(force: true)
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.watchers > 0 else { return }
                self.refresh(force: true)
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        ticker?.cancel()
        ticker = nil
    }

    /// A debrief the person said Later to, in this run of the app: its card steps aside until the
    /// next press, and the shelf keeps the count.
    func holdDebrief(_ sessionID: String) { heldDebriefs.insert(sessionID) }
    func releaseDebrief(_ sessionID: String) { heldDebriefs.remove(sessionID) }
    func isHeld(_ sessionID: String) -> Bool { heldDebriefs.contains(sessionID) }

    /// Why no expert can be made right now: the machines that keep experts are not answering, or
    /// no machine here keeps them. An offline machine never reads as one that cannot.
    var unreachableWords: String {
        let silent = board.unanswered.map(\.machine)
        guard silent.isEmpty else { return Self.notAnswering(silent) }
        return ExpertWords.cannotKeep(ConnectionController.shared.profiles.first?.name ?? "—")
    }

    /// The machines that keep experts and did not answer this read, in the app's offline words.
    var notAnsweringLine: String? {
        let silent = board.unanswered.map(\.machine)
        return silent.isEmpty ? nil : Self.notAnswering(silent)
    }

    static func notAnswering(_ machines: [String]) -> String {
        machines.map { ExpertWords.notAnswering($0) }.joined(separator: "\n")
    }

    /// Whether a machine keeps experts, asked of the machine rather than guessed.
    static func keepsExperts(_ backend: (any CodingAgentBackend)?) -> Bool {
        guard let backend else { return false }
        return backend.capabilities.supportsExperts && backend is any MachineExperts
    }
}

/// How an expert's colours, marks and tones are drawn here.
@MainActor
enum ExpertStyle {
    static func color(_ hue: ExpertHue) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? hue.rgb.dark : hue.rgb.light
            return UIColor(rgb: value)
        }
    }

    static func color(_ tone: ExpertTone) -> UIColor {
        switch tone {
        case .quiet: return Theme.Color.secondaryLabel
        case .active: return Theme.Color.accent
        case .attention: return Theme.Color.warning
        case .failing: return Theme.Color.danger
        case .good: return Theme.Color.success
        }
    }

    /// The mark as a picture, for a list cell that takes an image: the glyph on a tile of the
    /// expert's colour, lighter at the top-left, drawn for the appearance it will be shown in.
    static func mark(
        glyph: String, hue: ExpertHue, side: CGFloat = 30, traits: UITraitCollection = .current
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let base = color(hue).resolvedColor(with: traits)
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.28)
            path.addClip()
            let colors = [base.cgColor, base.shaded(by: 0.72).cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            let font = UIFont.systemFont(ofSize: side * 0.42, weight: .bold)
            let ink: UIColor = hue.wantsDarkGlyph ? UIColor.black.withAlphaComponent(0.85) : .white
            let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: ink])
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }.withRenderingMode(.alwaysOriginal)
    }

    static func mark(_ row: ExpertRow, side: CGFloat = 30, traits: UITraitCollection = .current) -> UIImage {
        mark(glyph: row.expert.glyph, hue: row.hue, side: side, traits: traits)
    }

    /// A small round lamp in a tone, for a bench row or a guard.
    static func lamp(_ tone: ExpertTone, side: CGFloat = 10) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            color(tone).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    static let symbol = "person.crop.rectangle.stack"
}

extension UIColor {
    convenience init(rgb value: UInt32) {
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    func shaded(by factor: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
        return UIColor(red: red * factor, green: green * factor, blue: blue * factor, alpha: alpha)
    }
}

/// The mark as a view: the glyph on the expert's colour, redrawn for the appearance it is in.
final class ExpertMarkView: UIView {
    private let imageView = UIImageView()
    private var glyph = ""
    private var hue = ExpertHue.blue
    private let side: CGFloat

    init(side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ExpertMarkView, _) in view.redraw() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(glyph: String, hue: ExpertHue) {
        guard glyph != self.glyph || hue != self.hue || imageView.image == nil else { return }
        self.glyph = glyph
        self.hue = hue
        redraw()
    }

    func show(_ row: ExpertRow) { show(glyph: row.expert.glyph, hue: row.hue) }

    private func redraw() {
        imageView.image = ExpertStyle.mark(glyph: glyph, hue: hue, side: side, traits: traitCollection)
    }
}

/// Chips that wrap onto as many lines as they need, each a capsule of words in a tone.
final class ExpertChipsView: UIView {
    private var chips: [UIView] = []
    private let spacing: CGFloat = 6
    private let lineSpacing: CGFloat = 6
    var centered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ lines: [ExpertLine], selected: Set<String> = [], onTap: ((String) -> Void)? = nil) {
        chips.forEach { $0.removeFromSuperview() }
        chips = lines.map { line in
            let isSelected = selected.contains(line.text)
            var config = UIButton.Configuration.plain()
            config.title = line.text
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updated = attributes
                updated.font = Theme.Ramp.font(.chip)
                return updated
            }
            if line.tone != .quiet {
                config.image = ExpertStyle.lamp(line.tone, side: 7)
                config.imagePadding = 6
            }
            config.background.backgroundColor = isSelected ? Theme.Color.accent : Self.fill
            config.baseForegroundColor = isSelected ? Theme.Color.onAccent : Theme.Color.label
            let button = UIButton(configuration: config)
            button.isUserInteractionEnabled = onTap != nil
            if let onTap {
                button.addAction(UIAction { _ in onTap(line.text) }, for: .touchUpInside)
                button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            }
            addSubview(button)
            return button
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place(width: bounds.width, apply: true)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: place(width: bounds.width > 0 ? bounds.width : 320, apply: false))
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
        verticalFittingPriority vertical: UILayoutPriority
    ) -> CGSize {
        CGSize(width: targetSize.width, height: place(width: targetSize.width, apply: false))
    }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        var lines: [[(UIView, CGSize)]] = [[]]
        var lineWidth: CGFloat = 0
        for chip in chips {
            let size = chip.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let fitted = CGSize(width: min(size.width, width), height: size.height)
            if lineWidth > 0, lineWidth + spacing + fitted.width > width {
                lines.append([])
                lineWidth = 0
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + fitted.width
            lines[lines.count - 1].append((chip, fitted))
        }
        var y: CGFloat = 0
        for line in lines where !line.isEmpty {
            let total = line.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(line.count - 1)
            var x: CGFloat = centered ? max(0, (width - total) / 2) : 0
            let height = line.map(\.1.height).max() ?? 0
            for (chip, size) in line {
                if apply { chip.frame = CGRect(x: x, y: y, width: size.width, height: size.height) }
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
        let height = max(0, y - lineSpacing)
        if apply, abs(height - lastHeight) > 0.5 {
            lastHeight = height
            invalidateIntrinsicContentSize()
        }
        return height
    }

    private var lastHeight: CGFloat = 0

    /// A capsule's ground that reads on every page it sits on, grouped or plain, light or dark.
    static let fill = UIColor { traits in Theme.Color.label.resolvedColor(with: traits).withAlphaComponent(0.09) }
}

/// The few things a screen about an expert needs to reach in the rest of the app.
@MainActor
enum ExpertRouter {
    /// Shows an expert's page: beside the list on an iPad, pushed on a phone.
    static func open(_ row: ExpertRow, from controller: UIViewController) {
        Theme.Haptics.tap()
        let page = ExpertViewController(row: row)
        if let workspace = MachineRouter.home?.workspace, controller.presentingViewController == nil,
            !(controller.navigationController?.viewControllers.contains(where: { $0 is ExpertViewController }) ?? false)
        {
            workspace.show(place: page)
            return
        }
        if let nav = controller.navigationController {
            nav.pushViewController(page, animated: true)
        } else {
            controller.present(UINavigationController(rootViewController: page), animated: true)
        }
    }

    /// Every expert, as a page of its own.
    static func openShelf(from controller: UIViewController) {
        Theme.Haptics.tap()
        if let workspace = MachineRouter.home?.workspace {
            workspace.show(place: ExpertsViewController())
            return
        }
        controller.navigationController?.pushViewController(ExpertsViewController(), animated: true)
    }

    /// A new task for an expert, as a sheet: its composer, carrying a conversation when one is
    /// handed over, or starting from words already written.
    static func newTask(
        _ row: ExpertRow, carrying brief: ConversationBrief? = nil, text: String? = nil,
        from controller: UIViewController
    ) {
        Theme.Haptics.tap()
        let composer = ExpertTaskViewController(row: row, carry: brief, draft: text)
        let nav = UINavigationController(rootViewController: composer)
        nav.modalPresentationStyle = .formSheet
        controller.present(nav, animated: true)
    }

    /// A new expert: from a skill on the machine, or blank, on the machine the person picks.
    static func newExpert(from controller: UIViewController, sourceView: UIView? = nil) {
        let machines = ExpertDesk.shared.board.machines
        guard !machines.isEmpty else {
            let alert = UIAlertController(
                title: ExpertWords.newExpert, message: ExpertDesk.shared.unreachableWords, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Localized.text("OK"), style: .default))
            controller.present(alert, animated: true)
            return
        }
        let sheet = UIAlertController(title: ExpertWords.newExpert, message: nil, preferredStyle: .actionSheet)
        for machine in machines {
            let suffix = machines.count > 1 ? " · \(machine.machine)" : ""
            sheet.addAction(
                UIAlertAction(title: ExpertWords.makeFromSkill + suffix, style: .default) { _ in
                    ExpertSkillPickerViewController.present(profileID: machine.profileID, from: controller)
                })
            sheet.addAction(
                UIAlertAction(title: ExpertWords.makeBlank + suffix, style: .default) { _ in
                    ExpertEditorViewController.presentNew(
                        profileID: machine.profileID, draft: ExpertDraft(name: ""), from: controller)
                })
        }
        sheet.addAction(UIAlertAction(title: ExpertWords.cancel, style: .cancel))
        let anchor = sourceView ?? controller.view
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor?.bounds ?? .zero
        controller.present(sheet, animated: true)
    }

    /// Opens a conversation by its id from any screen about an expert.
    static func openChat(sessionID: String, from controller: UIViewController) {
        MachineRouter.openChat(sessionID: sessionID, from: controller)
    }

    /// Opens the conversation a task just started in, from the session the machine handed back:
    /// a chat that new is not in Home's listing yet, so opening it by id would wait for a read.
    static func openStarted(_ session: AgentSession, profileID: String, from controller: UIViewController) {
        guard let profile = ExpertDesk.shared.profile(profileID) else {
            return openChat(sessionID: session.id, from: controller)
        }
        let entry = SessionEntry(
            profileID: profile.id, profileName: profile.name, host: profile.baseURL.host ?? profile.name,
            backendType: profile.backend, session: session)
        Theme.Haptics.tap()
        let open: () -> Void = { MachineRouter.home?.land(on: entry) }
        if let root = controller.presentingViewController {
            root.dismiss(animated: true, completion: open)
        } else {
            open()
        }
    }

    /// A short message for a refusal the machine gave, said as a toast-free alert.
    static func report(_ error: Error, title: String, from controller: UIViewController) {
        MidgarLog.error("expert: \(title): \(error)", category: .session)
        let alert = UIAlertController(title: title, message: ExpertRouter.words(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localized.text("OK"), style: .default))
        controller.present(alert, animated: true)
    }

    static func words(_ error: Error) -> String {
        if case AgentError.http(_, let body) = error, !body.isEmpty {
            if let data = body.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = object["error"] as? String
            {
                return message
            }
            return body
        }
        return Localized.text("The machine did not answer. Try again in a moment.")
    }
}
