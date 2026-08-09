import Foundation

/// How this copy of the app got onto this machine, which decides what it may honestly offer to do
/// about a newer one.
///
/// The three clients are distributed three different ways and only one of them can install
/// anything: the phone's copy belongs to the App Store, and a desktop's copy was built from a
/// checkout that may or may not still be on the same disk. A surface that offered "Update"
/// identically on all three would be lying on at least two of them.
public struct AppInstall: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable, CaseIterable {
        /// Installed by the App Store, which is also the only thing that can replace it.
        case appStore
        /// A TestFlight build: newer than the store's copy by design.
        case testFlight
        /// Running in a simulator, where there is nothing to update.
        case simulator
        /// Built from a checkout on this machine, and that checkout is still here.
        case sourceBuild
        /// Running straight out of a build directory — somebody's working copy, mid-development.
        case developerBuild
        /// A binary somebody installed, with no checkout behind it that we can find.
        case standalone
        case unknown

        public var sentence: String {
            switch self {
            case .appStore: return Localized.text("installed from the App Store")
            case .testFlight: return Localized.text("a TestFlight build")
            case .simulator: return Localized.text("running in a simulator")
            case .sourceBuild: return Localized.text("built from a checkout on this machine")
            case .developerBuild: return Localized.text("running out of a build directory")
            case .standalone: return Localized.text("installed as a binary")
            case .unknown: return Localized.text("of unknown origin")
            }
        }
    }

    public let kind: Kind
    /// The marketing version alone. The build number lives beside it rather than inside it,
    /// because `1.9 (30)` parses as nothing and would make every comparison unavailable.
    public let version: String?
    public let build: String?
    public let provenance: VersionProvenance
    /// The checkout this build came from, when there is one.
    public let source: String?
    /// Where the running program lives, for an update that has to replace it.
    public let binary: String?
    public let installedAt: Date?

    public init(
        kind: Kind, version: String?, build: String? = nil, provenance: VersionProvenance,
        source: String? = nil, binary: String? = nil, installedAt: Date? = nil
    ) {
        self.kind = kind
        self.version = version
        self.build = build
        self.provenance = provenance
        self.source = source
        self.binary = binary
        self.installedAt = installedAt
    }

    /// Version and build together, the way a bug report needs them. Never the thing that gets
    /// compared.
    public var stamp: String? {
        guard let version else { return nil }
        guard let build, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// The comparable fact: the marketing version, and who said it.
    public var fact: VersionFact {
        VersionFact(text: version, provenance: provenance, readAt: installedAt)
    }
}

/// The newest thing published, and where that claim came from.
public struct AppRelease: Sendable, Equatable, Codable {
    public let version: String
    public let provenance: VersionProvenance
    public let notes: String?
    public let url: String?
    public let publishedAt: Date?
    /// When this answer was fetched — the thing that decides whether it is still worth believing.
    public let readAt: Date?
    /// Which storefront answered. Apple keeps a record per country and they do not agree, so the
    /// claim is worth nothing without the name of the shop that made it.
    public let storefront: String?

    public init(
        version: String, provenance: VersionProvenance, notes: String? = nil, url: String? = nil,
        publishedAt: Date? = nil, readAt: Date? = nil, storefront: String? = nil
    ) {
        self.version = version
        self.provenance = provenance
        self.notes = notes
        self.url = url
        self.publishedAt = publishedAt
        self.readAt = readAt
        self.storefront = storefront
    }

    public var fact: VersionFact {
        guard let storefront else {
            return VersionFact(text: version, provenance: provenance, readAt: readAt)
        }
        return VersionFact(
            text: Localized.text("%@ in the %@ store", version, storefront),
            provenance: provenance, readAt: readAt)
    }
}

/// What a checkout on this machine says about itself and its upstream — the desktop equivalent of
/// what the bridge reports about its own source directory, and read the same way, so a phone
/// updating a server and a desktop updating itself are the same story told twice.
public struct CheckoutState: Sendable, Equatable, Codable {
    public let path: String
    /// `git describe --tags --always --dirty`.
    public let describe: String?
    public let commit: String?
    public let isDirty: Bool
    /// Commits on the upstream this checkout has not got.
    public let behind: Int
    /// Commits this checkout has that the upstream has not. A fast-forward cannot cross these, so
    /// any of them means no press can update this tree.
    public let ahead: Int
    /// Subjects of the commits it is behind by, newest first.
    public let changes: [String]
    public let upstream: String?
    /// A toolchain able to rebuild is on this machine.
    public let canBuild: Bool

    public init(
        path: String, describe: String?, commit: String?, isDirty: Bool, behind: Int, ahead: Int = 0,
        changes: [String] = [], upstream: String? = nil, canBuild: Bool = true
    ) {
        self.path = path
        self.describe = describe
        self.commit = commit
        self.isDirty = isDirty
        self.behind = behind
        self.ahead = ahead
        self.changes = changes
        self.upstream = upstream
        self.canBuild = canBuild
    }

    /// Why this checkout cannot be pulled and rebuilt under one press, when it cannot.
    public var blocker: String? {
        if isDirty {
            return Localized.text(
                "The checkout at %@ has uncommitted changes, so nothing here will touch it.", path)
        }
        if upstream == nil {
            return Localized.text("The checkout at %@ tracks no upstream to update from.", path)
        }
        if ahead > 0 {
            return Localized.text(
                "The checkout at %@ has %@ commits of its own, so it cannot be fast-forwarded.",
                path, String(ahead))
        }
        if !canBuild {
            return Localized.text("No toolchain on this machine can rebuild %@.", path)
        }
        return nil
    }
}

/// Reading git's own output. Parsed here rather than in each desktop client so the two of them
/// cannot drift, and so the parsing is provable without a repository.
public enum CheckoutReport {
    public static func isDirty(porcelain: String) -> Bool {
        !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `git rev-list --count --left-right HEAD...@{u}` answers `<ahead>\t<behind>`.
    public static func divergence(_ output: String) -> (ahead: Int, behind: Int) {
        let parts = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else {
            return (0, 0)
        }
        return (ahead, behind)
    }

    public static func subjects(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func line(_ output: String) -> String? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// What the installer wrote down about the build it put in place.
///
/// The desktops install *away* from the checkout that built them — `~/.local/bin/tailscode`, an
/// `.app` copied somewhere — so the running binary has no way to walk back to its source the way
/// the bridge does. This file is the only link, and it is believed only after it has been checked
/// against the binary actually running: a stamp left by a previous install, or one describing a
/// binary somebody replaced by hand, must degrade to "we do not know" rather than send a build
/// command at the wrong tree.
public struct InstallStamp: Sendable, Equatable, Codable {
    public struct Binary: Sendable, Equatable, Codable {
        public let path: String
        public let size: Int
        public let modifiedAt: Date?

        public init(path: String, size: Int, modifiedAt: Date?) {
            self.path = path
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    public struct Source: Sendable, Equatable, Codable {
        public let path: String
        public let describe: String?
        public let commit: String?
        public let branch: String?
        public let upstream: String?
        public let dirty: Bool

        public init(
            path: String, describe: String?, commit: String?, branch: String? = nil,
            upstream: String? = nil, dirty: Bool = false
        ) {
            self.path = path
            self.describe = describe
            self.commit = commit
            self.branch = branch
            self.upstream = upstream
            self.dirty = dirty
        }
    }

    public static let currentSchema = 1

    public let schema: Int
    public let component: String
    public let installedAt: Date?
    /// Which script put it here — `scripts/install-linuxapp.sh`, `self-update`, a package.
    public let installedBy: String?
    public let flavour: String?
    public let binary: Binary?
    public let source: Source?
    public let marketingVersion: String?

    public init(
        schema: Int = InstallStamp.currentSchema, component: String, installedAt: Date?,
        installedBy: String? = nil, flavour: String? = nil, binary: Binary? = nil,
        source: Source? = nil, marketingVersion: String? = nil
    ) {
        self.schema = schema
        self.component = component
        self.installedAt = installedAt
        self.installedBy = installedBy
        self.flavour = flavour
        self.binary = binary
        self.source = source
        self.marketingVersion = marketingVersion
    }

    /// What the running program can see for itself, handed in so the decision stays testable.
    public struct Evidence: Sendable, Equatable {
        public let executablePath: String
        public let size: Int?
        public let modifiedAt: Date?
        /// The recorded source path still holds a checkout, and it still has the commit this
        /// binary was built from.
        public let sourceIsCheckout: Bool
        public let sourceHasCommit: Bool

        public init(
            executablePath: String, size: Int?, modifiedAt: Date?, sourceIsCheckout: Bool,
            sourceHasCommit: Bool
        ) {
            self.executablePath = executablePath
            self.size = size
            self.modifiedAt = modifiedAt
            self.sourceIsCheckout = sourceIsCheckout
            self.sourceHasCommit = sourceHasCommit
        }
    }

    /// Whether this stamp describes the program that is running. A mismatch is not an error worth
    /// showing anybody — it just means the stamp is not evidence, and the surface falls back to a
    /// compiled-in constant it labels as such.
    public func describes(_ evidence: Evidence) -> Bool {
        guard schema <= Self.currentSchema, let binary else { return false }
        guard binary.path == evidence.executablePath else { return false }
        if let size = evidence.size, size != binary.size { return false }
        if let stampTime = binary.modifiedAt, let onDisk = evidence.modifiedAt,
            abs(stampTime.timeIntervalSince(onDisk)) > 2
        {
            return false
        }
        guard let source else { return false }
        guard !source.dirty else { return false }
        return evidence.sourceIsCheckout && evidence.sourceHasCommit
    }

    public static func decode(_ data: Data) -> InstallStamp? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallStamp.self, from: data)
    }
}

/// The desktop app updating itself: pull, rebuild, reinstall, come back.
///
/// It is the bridge's own update strategy pointed at this machine. The work cannot run inside the
/// process it replaces, so it is written to a script, detached from this process group, and
/// followed through a state file that outlives the restart — which is the only way the answer
/// survives the app going away in the middle of the job it was asked to do.
///
/// Every stage is guarded. A build that fails must never fall through to installing whatever was
/// in the build directory from last week and then report that it succeeded: that is the app
/// claiming to be running a version it is not, which is the worst thing this whole surface could
/// say.
public enum SourceUpdatePlan {
    /// Written by the detached script, read by whichever launch comes next.
    public static let stateFileName = "update.state.json"
    public static let logFileName = "update.log"

    public struct State: Sendable, Equatable, Codable {
        public enum Phase: String, Sendable, Equatable, Codable {
            case running
            case building
            case installing
            case restarting
            case succeeded
            case failed
        }

        public var phase: Phase
        public var startedAt: Date?
        public var finishedAt: Date?
        public var from: String?
        public var to: String?
        public var message: String?

        public init(
            phase: Phase, startedAt: Date? = nil, finishedAt: Date? = nil, from: String? = nil,
            to: String? = nil, message: String? = nil
        ) {
            self.phase = phase
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.from = from
            self.to = to
            self.message = message
        }

        public var isRunning: Bool {
            phase == .running || phase == .building || phase == .installing || phase == .restarting
        }

        public var step: UpdateProgress.Step {
            switch phase {
            case .running: return .starting
            case .building: return .building
            case .installing: return .installing
            case .restarting, .succeeded, .failed: return .restarting
            }
        }
    }

    /// The script writes ISO8601, because the app that reads it back is a different process on a
    /// different day. A bare epoch integer read by a stock `JSONDecoder` lands fifty-six years in
    /// the future, and everything downstream — "is this still running", "how long ago" — is then
    /// quietly wrong forever.
    public static func decodeState(_ data: Data) -> State? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// An unfinished job left behind by a process that was killed — a machine that slept, a build
    /// that was interrupted — is not running any more, whatever the file says. A start date in the
    /// future is a clock that moved, and is treated as unknown rather than as forever-fresh.
    public static func settled(_ state: State?, now: Date = Date()) -> State? {
        guard var state, state.isRunning else { return state }
        guard let started = state.startedAt, started <= now else {
            guard state.startedAt != nil else { return state }
            state.phase = .failed
            state.message = Localized.text("The update stopped without finishing.")
            return state
        }
        guard now.timeIntervalSince(started) > 45 * 60 else { return state }
        state.phase = .failed
        state.message = Localized.text("The update stopped without finishing.")
        return state
    }

    /// The shell the desktop hands off to.
    ///
    /// `waitFor` is the pid of the process being replaced: the app is single-instance on the
    /// session bus, so a relaunch while the old process is alive merely raises the old window and
    /// the person is left running the binary they were told had been replaced.
    ///
    /// `verify` is a command that must print the version the install produced; the script refuses
    /// to write `succeeded` unless it does, so "updated" is a fact about the binary on disk rather
    /// than about the script having reached its last line.
    public static func script(
        source: String, stateDirectory: String, build: [String], install: [String],
        relaunch: String, verify: String?, waitFor: Int32
    ) -> String {
        let guarded: ([String], String) -> String = { lines, label in
            lines.map { "\($0) || fail \(shellQuoted(label))" }.joined(separator: "\n")
        }
        return """
            #!/usr/bin/env bash
            set -uo pipefail
            SRC=\(shellQuoted(source))
            STATE_DIR=\(shellQuoted(stateDirectory))
            STATE="$STATE_DIR/\(stateFileName)"
            LOG="$STATE_DIR/\(logFileName)"
            mkdir -p "$STATE_DIR"
            : > "$LOG"

            now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
            escape() { printf '%s' "$1" | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g' | tr -d '\\n'; }
            write() {
                printf '{"phase":"%s","startedAt":"%s","finishedAt":%s,"from":"%s","to":"%s","message":"%s"}\\n' \\
                    "$1" "$STARTED" "$2" "$(escape "$FROM")" "$(escape "$TO")" "$(escape "${3:-}")" \\
                    > "$STATE"
            }
            phase() { write "$1" null "${2:-}"; }
            fail() {
                echo "FAILED: $1" >> "$LOG"
                write failed "\\"$(now)\\"" "$1"
                exit 1
            }

            STARTED=$(now)
            FROM=""
            TO=""
            cd "$SRC" || fail "the checkout is gone"
            FROM=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)
            phase running
            [ -z "$(git status --porcelain 2>/dev/null)" ] || fail "the checkout has uncommitted changes"

            git pull --ff-only >>"$LOG" 2>&1 || fail "git pull refused — the checkout has diverged"
            TO=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)

            phase building
            \(guarded(build, "the build failed — nothing was installed"))

            phase installing
            \(guarded(install, "the new build could not be installed"))
            \(verify.map { "\($0) >>\"$LOG\" 2>&1 || fail 'the installed binary did not answer'" } ?? "")

            phase restarting
            for _ in $(seq 1 300); do
                kill -0 \(waitFor) 2>/dev/null || break
                sleep 0.2
            done
            kill -0 \(waitFor) 2>/dev/null && fail "the old process never quit, so the new one cannot start"
            write succeeded "\\"$(now)\\""
            \(relaunch) >>"$LOG" 2>&1 &
            exit 0
            """
    }

    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
