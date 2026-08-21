import Foundation
import TailscodeCore

/// What this copy of the Mac app is allowed to say about itself.
///
/// There is no store record to ask. The desktop shares the phone's bundle identifier, so an
/// iTunes lookup would answer with the *phone's* published version and this window would report a
/// number it has never run — the exact confident lie the whole update surface exists to prevent.
/// So there are only two facts here: the stamp inside this bundle, and — when the checkout that
/// built it is still on this disk — what that checkout says about its upstream.
enum MacAppInstall {
    /// Where a person reads about the app when nothing here can install anything.
    static let projectURL = "https://github.com/guitaripod/Tailscode"

    /// The marketing version alone. The build number lives beside it rather than inside it,
    /// because `1.9 (30)` parses as nothing and would make every comparison unavailable.
    static var version: String? { stamp("CFBundleShortVersionString") }
    static var build: String? { stamp("CFBundleVersion") }

    /// A bundle with nothing stamped in it — and the `dev` placeholder the CLI prints when there
    /// is nothing — must arrive as `nil` rather than as a version, so the provenance degrades to
    /// "nothing said where this came from" instead of claiming the bundle said `dev`.
    private static func stamp(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "dev" else { return nil }
        return trimmed
    }

    /// What this copy is, off the bundle alone where the App Store owns it: a copy the store
    /// installed is a copy only the store replaces, so there is no checkout to look for and
    /// nothing here that could act on one if it were found.
    static var install: AppInstall {
        #if TAILSCODE_MAS
            return AppInstall(
                kind: .appStore, version: version, build: build,
                provenance: version == nil ? .unknown : .appBundle,
                source: nil, binary: Bundle.main.executableURL?.path, installedAt: builtAt())
        #else
            let source = sourceDirectory()
            return AppInstall(
                kind: source == nil ? .standalone : .sourceBuild,
                version: version, build: build,
                provenance: version == nil ? .unknown : .appBundle,
                source: source, binary: Bundle.main.executableURL?.path, installedAt: builtAt())
        #endif
    }

    /// This app's own row, read off the disk it is installed on.
    ///
    /// Blocking — git and the toolchain probes are subprocesses — so it is asked for off the main
    /// actor. No `storeURL` is ever passed: see the note on this type.
    static func reading(at checkedAt: Date = Date()) -> UpdateReading {
        #if TAILSCODE_MAS
            let install = install
            return UpdateReadings.app(
                install: install, release: nil, checkout: nil, projectURL: projectURL,
                subtitle: install.kind.sentence)
        #else
            return checkoutBackedReading(at: checkedAt)
        #endif
    }

    #if !TAILSCODE_MAS
        private static func checkoutBackedReading(at checkedAt: Date) -> UpdateReading {
            let install = install
            let report = checkoutReading()
            let subtitle = subtitle(install: install, checkout: report.state)
            guard let state = report.state, report.staleReason == nil || state.behind > 0 else {
                return UpdateReadings.app(
                    install: install, release: nil, checkout: nil, failure: report.staleReason,
                    projectURL: projectURL, checkedAt: report.staleReason == nil ? checkedAt : nil,
                    subtitle: subtitle)
            }
            return UpdateReadings.app(
                install: install, release: nil, checkout: state, obstacle: obstacle(for: state),
                command: buildCommand(at: state.path), projectURL: projectURL,
                checkedAt: checkedAt, subtitle: subtitle)
        }

        /// A checkout, and — kept beside it rather than folded into it — why its comparison is not
        /// current. A fetch that failed leaves `rev-list` answering against whatever the last
        /// successful fetch left behind, and a surface that printed "up to date" off a week-old
        /// remote ref would be claiming a check nobody performed.
        struct CheckoutReading: Sendable {
            let state: CheckoutState?
            let staleReason: String?
        }

        static func checkoutReading() -> CheckoutReading {
            guard let path = sourceDirectory(),
                let porcelain = git(["status", "--porcelain"], in: path)
            else { return CheckoutReading(state: nil, staleReason: nil) }
            let upstream = git(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: path)
                .flatMap(CheckoutReport.line)
            var staleReason: String?
            if upstream != nil, git(["fetch", "--quiet"], in: path) == nil {
                staleReason = Localized.text(
                    "The checkout at %@ could not reach its remote, so nothing here knows whether a "
                        + "newer build exists.", path)
            }
            let divergence = upstream == nil
                ? (ahead: 0, behind: 0)
                : CheckoutReport.divergence(
                    git(["rev-list", "--count", "--left-right", "HEAD...@{u}"], in: path) ?? "")
            let changes = divergence.behind > 0
                ? CheckoutReport.subjects(
                    git(["log", "--pretty=format:%s", "-20", "HEAD..@{u}"], in: path) ?? "")
                : []
            let state = CheckoutState(
                path: path,
                describe: git(["describe", "--tags", "--always", "--dirty"], in: path)
                    .flatMap(CheckoutReport.line),
                commit: git(["rev-parse", "HEAD"], in: path).flatMap(CheckoutReport.line),
                isDirty: CheckoutReport.isDirty(porcelain: porcelain),
                behind: divergence.behind, ahead: divergence.ahead, changes: changes,
                upstream: upstream, canBuild: hasToolchain())
            return CheckoutReading(state: state, staleReason: staleReason)
        }

        /// Whether the machine holds what a rebuild needs, answered honestly rather than forced to
        /// no. It is not the same question as whether *this app* can take an update — see
        /// `obstacle` — but a machine missing Xcode or xcodegen cannot even run the command it is
        /// handed, and Core says so in its own words once `canBuild` is false.
        static func hasToolchain() -> Bool {
            run(["xcodebuild", "-version"], in: nil) != nil
                && run(["xcodegen", "--version"], in: nil) != nil
        }

        /// The sentence the app's own row wears under its title: what this copy is, and where the
        /// checkout that made it lives. What stands in the way of a press is deliberately absent —
        /// Core prints the obstacle inside the verdict, and a row that stated it twice would read
        /// as two different refusals.
        static func subtitle(install: AppInstall, checkout: CheckoutState?) -> String {
            guard let checkout else { return install.kind.sentence }
            return Localized.text("Built from the checkout at %@.", checkout.path)
        }

        /// Why no press here finishes the job, in this client's own words.
        ///
        /// `CheckoutState.blocker` speaks a fixed vocabulary and has no case for the real one: the
        /// tree can be clean, the toolchain present, and the build would still land on the very
        /// bundle this process is executing out of. It is said only where a press exists — a
        /// checkout with nothing to pull is up to date, and answering "cannot update itself" to a
        /// machine with nothing to install would trade a useful fact for a true irrelevance.
        /// Whatever the checkout itself objects to rides along, because the command handed over
        /// would hit that first.
        private static func obstacle(for checkout: CheckoutState) -> String? {
            guard checkout.behind > 0 else { return nil }
            let mine = Localized.text(
                "A rebuild takes xcodegen and a multi-minute xcodebuild, and what it produces is "
                    + "the bundle this process is running from — so the command is handed over "
                    + "rather than pressed here.")
            guard let blocker = checkout.blocker else { return mine }
            return "\(mine) \(blocker)"
        }

        /// The line that actually replaces this app, rather than Core's `git pull` fallback —
        /// which fetches the source and leaves the running bundle exactly as it was.
        private static func buildCommand(at path: String) -> String {
            "cd \(SourceUpdatePlan.shellQuoted(path)) && git pull && xcodegen generate && "
                + "xcodebuild -scheme TailscodeMac -configuration Release build"
        }

        /// The checkout this build came from, found by walking up from the bundle: an app run out
        /// of `build-mac/Build/Products/Debug` is five directories below the tree that made it. A
        /// directory only counts when it holds both the project this app is generated from and a
        /// repository to compare against — either alone is somebody else's folder.
        private static func sourceDirectory() -> String? {
            let manager = FileManager.default
            var directory = Bundle.main.bundleURL.deletingLastPathComponent()
            for _ in 0..<12 {
                let project = directory.appendingPathComponent("project.yml").path
                let repository = directory.appendingPathComponent(".git").path
                if manager.fileExists(atPath: project), manager.fileExists(atPath: repository) {
                    return directory.path
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { break }
                directory = parent
            }
            return nil
        }
    #endif

    private static func builtAt() -> Date? {
        guard let path = Bundle.main.executableURL?.path,
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    #if !TAILSCODE_MAS
        private static func git(_ arguments: [String], in directory: String) -> String? {
            run(["git"] + arguments, in: directory)
        }

        /// A command, run with its output captured and its failure reported as nothing at all.
        ///
        /// Not a login shell: an rc file that prints a banner would land in the middle of git's own
        /// output and be parsed as a version. The search path is widened by hand instead, because
        /// an app launched from Finder inherits `/usr/bin:/bin` and would never find a Homebrew
        /// xcodegen. Git is told to ask for nothing — a background check that stopped on a
        /// credential prompt would hang until the process died.
        private static func run(_ arguments: [String], in directory: String?) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private static var searchPath: String {
            let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
            let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            return (inherited + extras.filter { !inherited.contains($0) }).joined(separator: ":")
        }
    #endif
}
