import AppKit
import Darwin
import Foundation
import TailscodeCore

/// Whether this Mac is on a tailnet, and — when it is not — which of the states it is in.
///
/// The interface walk the phone does answers "is there an address" and nothing else: a Mac signed
/// out of its tailnet, one whose Tailscale has never been started, and one that has no Tailscale
/// at all are the same silence in `getifaddrs`, and they need three different things done about
/// them. So the CLI is asked first, exactly as the GTK client asks it, and the walk stays as the
/// floor underneath: a `utun` carrying a `100.64/10` address is proof of a tailnet even on a Mac
/// whose Tailscale cannot be run from here.
struct TailnetStatusMac: Sendable {
    let address: String?
    /// Which of the five states this machine is in, carried beside the address rather than
    /// derived from its absence — a missing address is what every failure has in common, and the
    /// differences are the part somebody can act on.
    let reading: TailscaleReading

    /// A Mac keeps its Tailscale in one of two places and its CLI in four: the app bundle carries
    /// its own command (the line Tailscale's own docs tell people to alias), and a machine that
    /// installed the open-source daemon has it wherever its package manager puts binaries.
    private static let appPaths = [
        "/Applications/Tailscale.app",
        userHome + "/Applications/Tailscale.app",
    ]

    private static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        userHome + "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/bin/tailscale",
    ]

    /// The person's own home folder rather than the process's. Inside a container `NSHomeDirectory`
    /// answers with the sandbox, so a per-user candidate built from it names a path that could not
    /// hold an application and the check silently stops asking the real question.
    private static let userHome = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()

    /// The Mac's own download page. Core names the Linux one because Core has no platform, and a
    /// remedy is the client's door to wire.
    static let downloadPage = "https://tailscale.com/download/mac"

    static func read() -> TailnetStatusMac {
        let onInterface = localAddress()
        let answer = runTailscale()
        guard let data = answer.output,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TailnetStatusMac(
                address: onInterface,
                reading: TailscaleReading.read(
                    found: answer.ran || appURL != nil, sandboxed: isSandboxed,
                    backendState: nil, address: onInterface))
        }
        let selfNode = root["Self"] as? [String: Any]
        let reported = (selfNode?["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
        let address = reported ?? onInterface
        return TailnetStatusMac(
            address: address,
            reading: TailscaleReading.read(
                found: true, sandboxed: isSandboxed,
                backendState: root["BackendState"] as? String, address: address))
    }

    /// This Mac's Tailscale address off the interface list — a `100.64.0.0/10` (CGNAT) address on
    /// a `utun` interface, which exists only while the tunnel is up and configured.
    static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                let name = String(validatingCString: interface.ifa_name), name.hasPrefix("utun")
            else { continue }
            guard let address = numericHost(of: addr), isTailnetAddress(address) else { continue }
            return address
        }
        return nil
    }

    static var appURL: URL? {
        appPaths.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var cliPath: String? {
        cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The one thing to press, wired to a door this Mac actually has. Core says what the remedy
    /// means; the commands it carries are a Linux machine's, so none of them is shown here — on a
    /// Mac the daemon, the sign-in and the sign-out all live behind the Tailscale app, and the
    /// bare CLI is only the door when there is no app to open.
    static func door(for reading: TailscaleReading) -> TailnetDoor? {
        switch reading.remedy {
        case .none:
            return nil
        case .install:
            return .page(downloadPage)
        case .signIn, .start, .grantHostAccess:
            if let appURL { return .app(appURL) }
            #if TAILSCODE_MAS
                return .page(downloadPage)
            #else
                guard let cliPath else { return .page(downloadPage) }
                return .command(path: cliPath, arguments: ["up"])
            #endif
        }
    }

    private static var isSandboxed: Bool {
        #if TAILSCODE_MAS
            return true
        #else
            return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #endif
    }

    /// - Returns: whether the CLI ran at all, and what it printed. The two are separate facts: a
    ///   Mac with no Tailscale and one signed out of its tailnet both produce no usable JSON and
    ///   mean entirely different things.
    ///
    ///   A signed-out daemon answers with JSON *and* a non-zero status, and that JSON is the only
    ///   place `BackendState` says so — dropping it would collapse "signed out" into "not here".
    private static func runTailscale() -> (ran: Bool, output: Data?) {
        #if TAILSCODE_MAS
            return (false, nil)
        #else
            return runTailscaleCLI()
        #endif
    }

    #if !TAILSCODE_MAS
        private static func runTailscaleCLI() -> (ran: Bool, output: Data?) {
            guard let cliPath else { return (false, nil) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (false, nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return (true, data.isEmpty ? nil : data) }
            return (true, data)
        }
    #endif

    private static func numericHost(of addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        return buffer.withUnsafeMutableBufferPointer { host -> String? in
            guard let base = host.baseAddress,
                getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), base, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
            else { return nil }
            return String(validatingCString: base)
        }
    }

    private static func isTailnetAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

/// Where the one action goes on this machine. The words are the door's rather than the remedy's,
/// because a button that says "Sign in to Tailscale" and opens an app is a button that lied about
/// what pressing it does.
enum TailnetDoor: Sendable, Equatable {
    case page(String)
    case app(URL)
    #if !TAILSCODE_MAS
        case command(path: String, arguments: [String])
    #endif

    var title: String {
        switch self {
        case .page: return Localized.text("Get Tailscale")
        case .app: return Localized.text("Open Tailscale")
        #if !TAILSCODE_MAS
            case .command: return Localized.text("Sign in to Tailscale")
        #endif
        }
    }

    /// The line a person could run themselves, for the one door that is a command. It is offered
    /// as a copy beside the button rather than as an instruction: a press that cannot reach the
    /// daemon has to leave something behind, and a terminal is the floor, never the advice.
    var command: String? {
        #if TAILSCODE_MAS
            return nil
        #else
            guard case .command(let path, let arguments) = self else { return nil }
            return ([path] + arguments).joined(separator: " ")
        #endif
    }
}

/// The half of the tailnet step that is not the address: what is true, and the one press that
/// changes it. Shared by first run and the servers window so a Mac that is signed out reads the
/// same on both, and so the sign-in that has to be watched for a login URL is watched in one place.
@MainActor
final class TailnetRemedyView: NSView {
    private let column = FillingStack()
    private let detail = MacDialogs.detailLabel("", wraps: true)
    private let actions = NSStackView()
    private var shown: TailscaleReading?
    /// What a sign-in already running has printed so far, kept across a re-render so a poll that
    /// lands mid-flow does not wipe the output the person is reading.
    private var narration: String?

    init(inset: CGFloat = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A row is added or taken away rather than hidden in place: these two sit in a stack that
    /// stretches its children, and a detached child keeps the pins that stretched it.
    ///
    /// A reading that has not changed rebuilds nothing. The poll behind this view comes round every
    /// few seconds, and a button replaced under a finger is a button that swallowed the press —
    /// while a sign-in already running would lose the output it has printed so far.
    func write(_ reading: TailscaleReading) {
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        guard shown != reading else { return }
        shown = reading
        narration = nil
        let door = TailnetStatusMac.door(for: reading)
        let text = reading.detail ?? ""
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !text.isEmpty {
            detail.stringValue = text
            column.addArrangedSubview(detail)
        }
        isHidden = text.isEmpty && door == nil
        guard let door else { return }
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.addArrangedSubview(
            RowKit.ActionButton(title: door.title) { [weak self] in
                self?.enter(door)
            })
        if let command = door.command {
            let copy = RowKit.ActionButton(title: Localized.text("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            copy.bezelStyle = .accessoryBar
            actions.addArrangedSubview(copy)
        }
        actions.addArrangedSubview(RowKit.spacer())
        column.addArrangedSubview(actions)
    }

    /// The door this reading offers, walked from somewhere else. A diagnosis on another surface names
    /// the same remedy — `ConnectDiagnosis.Fix.openTailscale` is one sentence on every screen that
    /// probes anything — and it has to land on this press rather than on a second copy of it.
    func enterDoor() {
        guard let reading = shown, let door = TailnetStatusMac.door(for: reading) else { return }
        enter(door)
    }

    /// One door, walked. Internal rather than private because a surface can be blocked by a reading
    /// that is not the one this view is showing — a scan needs Tailscale's command line, which a Mac
    /// whose tunnel is up can perfectly well be without — and that press has to land on this walker
    /// rather than on a second copy of it.
    func enter(_ door: TailnetDoor) {
        switch door {
        case .page(let address):
            guard let url = URL(string: address) else { return }
            NSWorkspace.shared.open(url)
        case .app(let url):
            NSWorkspace.shared.open(url)
        #if !TAILSCODE_MAS
            case .command(let path, let arguments):
                run(path, arguments)
        #endif
        }
    }

    /// A command that has to run on *this* Mac is run from here, with its output on the same
    /// screen, rather than handed over with "run it in a terminal" — the one thing the first-run
    /// doctrine forbids, and useless advice to somebody who has never opened one.
    ///
    /// `tailscale up` answers by printing a login URL and waiting, so the output is watched and the
    /// URL opened as it appears. A command this Mac will not run says so and leaves the copyable
    /// line, which is the honest floor rather than a silent failure.
    #if !TAILSCODE_MAS
        private func run(_ path: String, _ arguments: [String]) {
            let command = ([path] + arguments).joined(separator: " ")
            narrate(Localized.text("Running %@…", command))
            Task.detached(priority: .utility) { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                guard (try? process.run()) != nil else {
                    await MainActor.run {
                        self?.narrate(
                            Localized.text(
                                "This Mac would not run %@. Copy it and run it yourself, then this "
                                    + "step turns green on its own.", command))
                    }
                    return
                }
                var seen = ""
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096),
                    !chunk.isEmpty
                {
                    seen += String(decoding: chunk, as: UTF8.self)
                    let text = seen
                    if let url = Self.loginURL(in: text) {
                        seen = ""
                        await MainActor.run { NSWorkspace.shared.open(url) }
                    }
                    await MainActor.run {
                        self?.narrate(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                process.waitUntilExit()
            }
        }
    #endif

    private func narrate(_ text: String) {
        narration = text.isEmpty ? nil : text
        detail.font = MacTheme.Ramp.font(.panelFootnote)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.stringValue = text
        if detail.superview == nil { column.insertArrangedSubview(detail, at: 0) }
        isHidden = false
    }

    /// Tailscale's own sign-in link, which is the whole point of watching the output: somebody who
    /// never sees it has no way to finish signing in.
    private nonisolated static func loginURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace })
        where token.hasPrefix("https://login.tailscale.com/") {
            return URL(string: String(token))
        }
        return nil
    }
}
