import Foundation
import TailscodeCore

/// What this copy of the desktop client actually is, and what it may honestly offer to do about a
/// newer one.
///
/// The binary is installed *away* from the checkout that built it — `~/.local/bin/tailscode` — so
/// the running program has no way to walk back to its source the way the bridge does. The installer
/// leaves a stamp beside its state, and the stamp is believed only after it has been checked
/// against the binary that is actually running: one left by an earlier install, or one describing a
/// binary somebody replaced by hand, degrades to "we do not know" rather than sending a build
/// command at the wrong tree.
enum LinuxAppInstall {
    static let component = "tailscode-linux"

    /// Where the installer, the update script and the update's own state all meet. `XDG_STATE_HOME`
    /// rather than the config directory: none of this is a preference, and a person restoring their
    /// settings onto another machine must not inherit a claim about a binary that machine never had.
    static var stateDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        return base.appendingPathComponent("tailscode", isDirectory: true)
    }

    static var stampURL: URL { stateDirectory.appendingPathComponent("install.json") }
    static var scriptURL: URL { stateDirectory.appendingPathComponent("self-update.sh") }

    static var stateURL: URL {
        stateDirectory.appendingPathComponent(SourceUpdatePlan.stateFileName)
    }

    static var logURL: URL { stateDirectory.appendingPathComponent(SourceUpdatePlan.logFileName) }

    /// What this build is, decided in the order the evidence deserves: a stamp that survives being
    /// checked against the running binary is the only thing that can name a checkout, a path under
    /// `.build/` is somebody's working copy whatever a stamp says, and everything else is a binary
    /// with nothing behind it that we can find.
    static func read() -> AppInstall {
        let executable = DesktopGuard.executablePath
        if let stamp = stamp(), stamp.describes(evidence(for: stamp, executable: executable)) {
            return AppInstall(
                kind: .sourceBuild,
                version: stampedVersion(stamp) ?? TailscodeVersion.current,
                provenance: .installStamp, source: stamp.source?.path,
                binary: stamp.binary?.path ?? executable, installedAt: stamp.installedAt)
        }
        if DesktopGuard.isDevelopmentBuild {
            return AppInstall(
                kind: .developerBuild, version: TailscodeVersion.current, provenance: .appBundle,
                binary: executable)
        }
        return AppInstall(
            kind: .standalone, version: TailscodeVersion.current, provenance: .appBundle,
            binary: executable)
    }

    static func stamp() -> InstallStamp? {
        guard let data = try? Data(contentsOf: stampURL) else { return nil }
        return InstallStamp.decode(data)
    }

    /// The version a stamp actually claims, or nothing at all.
    ///
    /// Both writers are `printf` templates that always emit the key, so a build whose `--version`
    /// answered nothing leaves an empty string behind rather than an absent field — and an empty
    /// string is not nil, which is how the compiled-in fallback beside it came to never fire and
    /// this surface came to compare a running build against "".
    private static func stampedVersion(_ stamp: InstallStamp) -> String? {
        guard
            let version = stamp.marketingVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty
        else { return nil }
        return version
    }

    private static func evidence(for stamp: InstallStamp, executable: String)
        -> InstallStamp.Evidence
    {
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
        let source = stamp.source?.path
        return InstallStamp.Evidence(
            executablePath: executable,
            size: (attributes?[.size] as? NSNumber)?.intValue,
            modifiedAt: attributes?[.modificationDate] as? Date,
            sourceIsCheckout: source.map(isCheckout) ?? false,
            sourceHasCommit: hasCommit(stamp.source?.commit, in: source))
    }

    /// A directory that is a checkout of *this* project rather than merely some git repository. The
    /// client's package sits one level below the repository a stamp names — the build step is
    /// `cd <source>/TailscodeLinux` — so the manifest is looked for in both places.
    private static func isCheckout(_ path: String) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: path + "/.git") else { return false }
        return files.fileExists(atPath: path + "/Package.swift")
            || files.fileExists(atPath: path + "/TailscodeLinux/Package.swift")
    }

    /// Whether the checkout still holds the commit this binary was built from. A tree somebody has
    /// since reset or re-cloned is not the tree that produced what is running, and a stamp pointing
    /// at it is a claim rather than evidence.
    private static func hasCommit(_ commit: String?, in path: String?) -> Bool {
        guard let commit, !commit.isEmpty, let path else { return false }
        return git(["cat-file", "-e", "\(commit)^{commit}"], in: path).ok
    }

    /// What the checkout this build came from says about itself and its upstream — read exactly the
    /// way the bridge reads its own source directory, so a phone updating a server and this desk
    /// updating itself are the same story told twice.
    ///
    /// - Parameter fetching: whether to consult the remote. It costs a network round trip and is
    ///   the one part of this reading that goes stale, so a launch that is not due skips it and the
    ///   surface carries the moment of the last fetch forward rather than claiming a fresh one.
    static func checkout(of install: AppInstall = read(), fetching: Bool = true) -> CheckoutState? {
        guard let path = install.source, isCheckout(path) else { return nil }
        let dirty = CheckoutReport.isDirty(
            porcelain: git(["status", "--porcelain"], in: path).output)
        let upstream = git(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: path
        ).line
        if fetching, upstream != nil { _ = git(["fetch", "--quiet"], in: path) }

        var ahead = 0
        var behind = 0
        var changes: [String] = []
        if upstream != nil {
            let counts = git(["rev-list", "--count", "--left-right", "HEAD...@{u}"], in: path)
            if counts.ok { (ahead, behind) = CheckoutReport.divergence(counts.output) }
            if behind > 0 {
                changes = CheckoutReport.subjects(
                    git(["log", "--pretty=format:%s", "-20", "HEAD..@{u}"], in: path).output)
            }
        }
        return CheckoutState(
            path: path,
            describe: git(["describe", "--tags", "--always", "--dirty"], in: path).line,
            commit: git(["rev-parse", "HEAD"], in: path).line,
            isDirty: dirty, behind: behind, ahead: ahead, changes: changes, upstream: upstream,
            canBuild: canBuild)
    }

    /// Whether the update's own build step will find a toolchain. The detached script inherits this
    /// process's environment, so the honest question is about *this* `PATH` rather than about what
    /// a login shell would resolve in a terminal nobody is going to open.
    static var canBuild: Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let files = FileManager.default
        return path.split(separator: ":").contains {
            files.isExecutableFile(atPath: "\($0)/swift")
        }
    }

    /// The update that is running, or the corpse of the one that was: written by a script that
    /// outlives this process, so the answer survives the app going away in the middle of the job it
    /// was asked to do. Already settled, so a job whose process was killed reads as failed rather
    /// than as forever-building.
    static func updateState(now: Date = Date()) -> SourceUpdatePlan.State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return SourceUpdatePlan.settled(SourceUpdatePlan.decodeState(data), now: now)
    }

    /// The last update's own log, for a failure that needs more than one sentence.
    static func updateLog() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pulls, rebuilds, reinstalls and comes back — the bridge's own update strategy pointed at this
    /// machine. Answers nil once the work has been handed off, and the sentence to show otherwise.
    ///
    /// The work cannot run inside the process it replaces, so it is written to a script, detached
    /// from this process group with `setsid`, and followed through a state file. Nothing quits here:
    /// the caller keeps rendering the script's own phase, so a build that fails leaves the person
    /// exactly where they were rather than closing their window to no purpose.
    static func selfUpdate(install: AppInstall = read()) -> String? {
        if let obstacle = obstacle(for: install) { return obstacle }
        guard let source = install.source, isCheckout(source) else {
            return Localized.text("Nothing here knows which checkout this build came from.")
        }
        guard let binary = install.binary else { return Self.noBinary }
        guard canBuild else {
            return Localized.text("No toolchain on this machine can rebuild %@.", source)
        }
        let package = source + "/TailscodeLinux"
        let script = SourceUpdatePlan.script(
            source: source, stateDirectory: stateDirectory.path,
            build: ["cd \(quoted(package)) && swift build -c release --manifest-cache none"],
            install: [
                "install -m 0755 \(quoted(package + "/.build/release/tailscode")) \(quoted(binary))",
                stampLine(binary: binary),
            ],
            relaunch: quoted(binary), verify: "\(quoted(binary)) --version", waitFor: getpid())
        do {
            try FileManager.default.createDirectory(
                at: stateDirectory, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return Localized.text("The update script could not be written: %@", "\(error)")
        }
        return detach(scriptURL.path)
    }

    /// Why a press on this desk cannot finish, in the words the press itself would answer with.
    ///
    /// The checkout reports on the tree and Core reads that report; this is the part only the
    /// running program can see — a build directory whose rebuild would land on top of the binary
    /// executing this line, and a binary that is no longer there to be replaced. Shared with
    /// ``selfUpdate(install:)`` so what the row refuses and what the button refuses cannot end up
    /// being two different sentences.
    static func obstacle(for install: AppInstall = read()) -> String? {
        if DesktopGuard.isDevelopmentBuild {
            return Localized.text(
                "This is running straight out of a build directory — install it before asking it to "
                    + "update itself.")
        }
        guard let binary = install.binary, FileManager.default.isExecutableFile(atPath: binary)
        else { return Self.noBinary }
        return nil
    }

    private static var noBinary: String {
        Localized.text("Nothing here knows which binary an update would replace.")
    }

    /// The line that finishes the job by hand on this desk, for the rows where no press can.
    ///
    /// Core's own guess is `git pull`, which is the wrong line here whatever the state of the tree:
    /// it moves the checkout and leaves the binary on `PATH` exactly as it was, so a person who ran
    /// it would watch the app go on reporting the version they had just been told they were past.
    static func handCommand(of checkout: CheckoutState) -> String {
        "cd \(quoted(checkout.path)) && scripts/install-linuxapp.sh"
    }

    /// The line that rewrites the stamp, run inside the update script where `$SRC` and `$TO` are the
    /// checkout and what it landed on. The new binary is asked for its own version rather than being
    /// told one: the script cannot know what marketing number the build it just made carries.
    private static func stampLine(binary: String) -> String {
        let bin = quoted(binary)
        let format = "{\"schema\":\(InstallStamp.currentSchema),\"component\":\"\(component)\","
            + "\"installedAt\":\"%s\",\"installedBy\":\"self-update\",\"flavour\":\"release\","
            + "\"binary\":{\"path\":\"%s\",\"size\":%s,\"modifiedAt\":\"%s\"},"
            + "\"source\":{\"path\":\"%s\",\"describe\":\"%s\",\"commit\":\"%s\",\"branch\":\"%s\","
            + "\"upstream\":\"%s\",\"dirty\":false},\"marketingVersion\":\"%s\"}\\n"
        let arguments = [
            "\"$(now)\"",
            bin,
            "\"$(stat -c %s \(bin))\"",
            "\"$(date -u -r \(bin) +%Y-%m-%dT%H:%M:%SZ)\"",
            "\"$SRC\"",
            "\"$TO\"",
            "\"$(git -C \"$SRC\" rev-parse HEAD)\"",
            "\"$(git -C \"$SRC\" rev-parse --abbrev-ref HEAD)\"",
            "\"$(git -C \"$SRC\" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)\"",
            "\"$(\(bin) --version 2>/dev/null | awk '{print $NF}')\"",
        ].joined(separator: " ")
        return "mkdir -p \(quoted(stateDirectory.path)) && printf '\(format)' \(arguments) > "
            + quoted(stampURL.path)
    }

    /// Starts the script in a session of its own and waits for it to say so. Answers nil once the
    /// work is genuinely under way, and the sentence to show otherwise.
    ///
    /// A child of this process group dies with the app it was told to replace, which is exactly the
    /// moment it has work left to do — hence `setsid`, with `nohup` behind it for a machine that has
    /// no such thing. Neither launcher can be judged by whether it *started*: `env` exits 127 when
    /// it cannot find one, and a press that read that as a handoff would do nothing, say nothing,
    /// and leave the surface waiting three quarters of an hour on a phase that never arrives.
    /// Neither can be waited out either — `setsid` execs the script in place rather than forking
    /// whenever it is not already a process group leader, so on this desk the launcher stays alive
    /// for the whole build and there is no exit status coming. What is waited for is the handoff
    /// itself: a state file touched since the launch, or a launcher still alive to have touched it.
    private static func detach(_ path: String) -> String? {
        var refused: [String] = []
        for launcher in [["setsid", path], ["nohup", path]] {
            let name = launcher[0]
            let launchedAt = Date()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = launcher
            process.environment = relaunchEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                refused.append(Localized.text("%@ could not be run (%@)", name, "\(error)"))
                continue
            }
            switch handoff(since: launchedAt, launcher: process) {
            case .reported:
                return nil
            case .exited(let status):
                refused.append(Localized.text("%@ exited %@", name, String(status)))
            }
        }
        return Localized.text(
            "Nothing here could start the update script: %@.", refused.joined(separator: "; "))
    }

    /// How the handoff ended. A launcher that is *still alive* counts as reported: `env` becomes
    /// the launcher and the launcher becomes the script, so a live process at this point is the
    /// update running, whether or not it has got as far as writing anything down. Only a launcher
    /// that is gone and left nothing behind is a failure worth falling through for — which also
    /// keeps a slow start from being answered by starting a second copy of the same build.
    private enum Handoff {
        case reported
        case exited(Int32)
    }

    /// How long the press may block waiting for the script's first written word. Short, because it
    /// blocks the hand that pressed the button: the script writes its phase before it fetches
    /// anything, and a launcher that is not on this machine at all dies in milliseconds.
    private static let handoffWindow: TimeInterval = 3
    /// How long a launcher that has exited is given to have left a state file behind. `setsid` does
    /// fork and exit 0 when it is already a process group leader, and the script it left running is
    /// a few milliseconds behind it.
    private static let graceAfterExit: TimeInterval = 0.5

    private static func handoff(since launchedAt: Date, launcher: Process) -> Handoff {
        let deadline = launchedAt.addingTimeInterval(handoffWindow)
        var exitedAt: Date?
        while Date() < deadline {
            if stateWritten(since: launchedAt) { return .reported }
            if !launcher.isRunning {
                let seen = exitedAt ?? Date()
                exitedAt = seen
                guard Date().timeIntervalSince(seen) < graceAfterExit else {
                    return .exited(launcher.terminationStatus)
                }
            }
            usleep(50_000)
        }
        if stateWritten(since: launchedAt) { return .reported }
        return launcher.isRunning ? .reported : .exited(launcher.terminationStatus)
    }

    /// Whether the state file belongs to *this* launch. A corpse from last week's update sits at
    /// the same path, and taking it for a handoff would report a build that never started.
    private static func stateWritten(since launchedAt: Date) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return false }
        return modified >= launchedAt.addingTimeInterval(-1)
    }

    /// What the new process inherits. The desk it opens on has to be the desk this one is on, so the
    /// display and the session bus travel; everything that made *this* launch a driven or traced one
    /// does not, because a relaunch that re-ran a drive script or refused the real display would be
    /// the update handing back a different app than the one that was replaced.
    private static var relaunchEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["TAILSCODE_DRIVE", "TAILSCODE_COMPOSER", DesktopGuard.harnessVariable, "TAILSCODE_TRACE"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private static func quoted(_ value: String) -> String {
        SourceUpdatePlan.shellQuoted(value)
    }

    /// git, asked directly rather than through a shell. A login shell resolves the aliases a person
    /// relies on, which is right for the terminal pane and wrong here: this output is parsed, and a
    /// profile that prints one line of its own would be read as a commit subject or a commit count.
    private static func git(_ arguments: [String], in directory: String) -> GitAnswer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return GitAnswer(output: "", ok: false) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitAnswer(
            output: String(data: data, encoding: .utf8) ?? "", ok: process.terminationStatus == 0)
    }

    /// What git said and whether it meant it. The exit status is the whole reason this is not a
    /// plain string: `rev-parse @{upstream}` in a branch that tracks nothing prints a diagnosis and
    /// fails, and a caller reading only the text would take the diagnosis for a branch name.
    private struct GitAnswer {
        let output: String
        let ok: Bool

        var line: String? { ok ? CheckoutReport.line(output) : nil }
    }
}
