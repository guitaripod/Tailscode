import Foundation

/// One machine in the picture whose software can be out of date.
public enum UpdateComponent: Sendable, Hashable, Codable {
    /// This client, on the desk it is running on.
    case app
    /// A configured server, by profile.
    case server(profileID: String)

    public var key: String {
        switch self {
        case .app: return "app"
        case .server(let id): return "server:\(id)"
        }
    }

    public var isApp: Bool { self == .app }
}

/// Where a version number came from, kept beside the number itself.
///
/// An update surface is a claim about two machines, and the whole difference between a useful
/// claim and a confident lie is whether the reader can tell who said it. A number Apple published
/// and a number read out of a directory are both "the version" and they mean entirely different
/// things when they disagree — so the exact number and its source are always one tap away, in the
/// details under every card, even where the card itself leads with the short form.
public enum VersionProvenance: String, Sendable, Hashable, Codable, CaseIterable {
    /// The stamp written when the running binary was built. The only reading that is a fact about
    /// the *process* rather than about a directory.
    case serverBuild
    /// `git describe` in the checkout the server was built from. This describes a directory: it
    /// moves when somebody checks out a branch on that machine, and it runs ahead of the running
    /// binary for the whole stretch between a build and a restart.
    case serverCheckout
    /// The server had no checkout to read and answered with the constant it was compiled with.
    case serverConstant
    /// The server named its own version and said nothing about where the number came from — which
    /// is all a machine that has no update route of its own can offer.
    case serverReported
    /// This build's own bundle.
    case appBundle
    /// The file the installer wrote beside the binary.
    case installStamp
    /// Apple's record for this bundle identifier, in one storefront.
    case appStore
    /// The project's published releases.
    case gitHubRelease
    /// A git checkout on this machine.
    case sourceCheckout
    /// Nothing could be read.
    case unknown

    /// Who said it, in the words the details print beside the number.
    public var sentence: String {
        switch self {
        case .serverBuild: return Localized.text("stamped when this build was made")
        case .serverCheckout:
            return Localized.text("read from the checkout on that machine, not from what is running")
        case .serverConstant:
            return Localized.text(
                "the version the server was built with — it has no checkout to read")
        case .serverReported: return Localized.text("what that server says it is")
        case .appBundle: return Localized.text("this build's own stamp")
        case .installStamp: return Localized.text("recorded when this build was installed")
        case .appStore: return Localized.text("Apple's App Store record")
        case .gitHubRelease: return Localized.text("the project's published releases")
        case .sourceCheckout: return Localized.text("the checkout this build was made from")
        case .unknown: return Localized.text("nothing said where this came from")
        }
    }

    /// Whether the number is a fact about the software that is actually running. A checkout's
    /// `describe` is not: it is a fact about a directory, and the two part company the moment
    /// somebody builds without restarting.
    public var isAuthoritative: Bool {
        switch self {
        case .serverBuild, .serverReported, .appBundle, .installStamp, .appStore, .gitHubRelease,
            .sourceCheckout:
            return true
        case .serverCheckout, .serverConstant, .unknown:
            return false
        }
    }
}

/// A version, who said it, and when — the smallest honest unit this surface deals in.
public struct VersionFact: Sendable, Hashable, Codable {
    public let text: String?
    public let provenance: VersionProvenance
    public let readAt: Date?

    public init(text: String?, provenance: VersionProvenance, readAt: Date? = nil) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.provenance = self.text == nil ? .unknown : provenance
        self.readAt = readAt
    }

    public static let unknown = VersionFact(text: nil, provenance: .unknown)

    public var isKnown: Bool { text != nil }
    public var parsed: SoftwareVersion? { text.flatMap(SoftwareVersion.init) }

    /// The version as a person reads it — the release it descends from — for the line a card leads
    /// with. The exact string and its source are ``line``.
    public var short: String? { VersionLabel.short(text) }

    /// The number with its source, which is the form the details show it in.
    public var line: String {
        guard let text else { return Localized.text("not reported") }
        return Localized.text("%@ · %@", text, provenance.sentence)
    }
}

/// An update that exists and what taking it would mean.
public struct UpdateOffer: Sendable, Equatable, Codable {
    /// What the machine would be running afterwards, when it can be named.
    public let version: String?
    /// How many commits behind, when the machine counts in commits.
    public let commits: Int?
    /// Subjects of what it would bring in, newest first.
    public let changes: [String]
    /// The line of development this is behind. Two machines on different branches are not two
    /// counts of the same thing, and a surface that folded them into one number would say so.
    public let upstream: String?
    /// Whether one press finishes the job on this machine.
    public let canInstallHere: Bool
    /// Why one press cannot finish it, when it cannot.
    public let blocked: String?
    /// The obstacle itself, named rather than merely summarised — the files that are dirty, the
    /// commits that are in the way, the places a toolchain was looked for.
    ///
    /// Deliberately outside ``UpdateReading/acknowledgeableIdentity``: an agent writing one more
    /// file on that machine changes this list, and an acknowledgement that expired every time the
    /// obstacle grew by a path would put the standing mark back for something nobody can act on
    /// any differently.
    public let details: [String]
    /// How many more there are than `details` carries.
    public let moreDetails: Int
    /// What the update brings, in the project's own words, newest release first.
    public let notes: [ReleaseNote]

    public init(
        version: String?, commits: Int? = nil, changes: [String] = [], upstream: String? = nil,
        canInstallHere: Bool, blocked: String? = nil, details: [String] = [], moreDetails: Int = 0,
        notes: [ReleaseNote] = []
    ) {
        self.version = version
        self.commits = commits
        self.changes = changes
        self.upstream = upstream
        self.canInstallHere = canInstallHere
        self.blocked = blocked
        self.details = details
        self.moreDetails = moreDetails
        self.notes = notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        commits = try container.decodeIfPresent(Int.self, forKey: .commits)
        changes = try container.decodeIfPresent([String].self, forKey: .changes) ?? []
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        canInstallHere = try container.decodeIfPresent(Bool.self, forKey: .canInstallHere) ?? false
        blocked = try container.decodeIfPresent(String.self, forKey: .blocked)
        details = try container.decodeIfPresent([String].self, forKey: .details) ?? []
        moreDetails = try container.decodeIfPresent(Int.self, forKey: .moreDetails) ?? 0
        notes = (try? container.decodeIfPresent([ReleaseNote].self, forKey: .notes)) ?? []
    }

    /// The obstacle's own list, with the tail it left out stated rather than dropped.
    public var detailLines: [String] {
        guard moreDetails > 0 else { return details }
        return details + [Localized.text("and %@ more", String(moreDetails))]
    }

    /// What it would become, named however the machine can name it.
    public var target: String {
        if let version { return VersionLabel.short(version) ?? version }
        if let commits, commits > 0 {
            return Localized.text("%@ commits newer", String(commits))
        }
        return Localized.text("a newer build")
    }

    /// What is new, as a person reads it: the project's notes where it sent them, and the headlines
    /// of its commits where it did not.
    public var whatsNew: [ReleaseNote] {
        guard notes.isEmpty else { return notes }
        return ReleaseNote.fromSubjects(changes)
    }
}
