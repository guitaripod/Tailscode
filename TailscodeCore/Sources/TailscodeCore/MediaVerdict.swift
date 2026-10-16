import CodingAgentKit
import Foundation

/// What the doctor found on one machine at one moment, read the ways the surfaces need it: is
/// ComfyUI answering, can the video lane render, can each picture engine, and in whose words.
public struct MediaVerdict: Sendable, Equatable {
    public let endpoint: ForgeEndpoint
    public let report: SetupReport
    public let at: Date

    public init(endpoint: ForgeEndpoint, report: SetupReport, at: Date = Date()) {
        self.endpoint = endpoint
        self.report = report
        self.at = at
    }

    public func check(_ id: String) -> SetupCheck? { report.checks.first { $0.id == id } }

    public enum Comfy: Sendable, Equatable {
        case answering(version: String?)
        case starting
        case refused
        case loopbackOnly
        case timedOut
        case unresolved
        case notComfy
    }

    public var comfy: Comfy {
        guard let check = check("media.comfy") else { return .notComfy }
        if check.state == .ok { return .answering(version: check.facts["version"]) }
        switch check.facts["phase"] {
        case "starting": return .starting
        case "refused": return .refused
        case "loopbackOnly": return .loopbackOnly
        case "timedOut": return .timedOut
        case "unresolved": return .unresolved
        default: return .notComfy
        }
    }

    public var isAnswering: Bool {
        if case .answering = comfy { return true }
        return false
    }

    public var isStarting: Bool { comfy == .starting }

    /// When to ask again: a ComfyUI that is starting is asked every few seconds until it answers,
    /// and nothing else is asked again by the clock.
    public var recheck: TimeInterval? { isStarting ? 5 : nil }

    /// What stands between this machine and a clip, or nil when nothing the doctor can see does.
    /// A machine that is not answering has no blocker of this kind: it is unknown, and the render
    /// asks it again itself.
    public var video: MediaBlocker? {
        guard isAnswering else { return nil }
        if let gone = blocker(nodes: "media.video.nodes", models: "media.video.models", lane: .video) {
            return gone
        }
        guard let gpu = check("media.gpu"), gpu.facts["none"] != nil else { return nil }
        return MediaBlocker(
            checkID: "media.gpu", sentence: MediaReading.line(for: gpu, in: self).detail, fix: nil)
    }

    /// A machine that answers, but not as a ComfyUI anybody can reach: nothing is listening, it
    /// listens for its own machine only, the name does not resolve or something else answers. No
    /// render can work until that changes. Silence and a socket that is loading are not here —
    /// those are a machine that may be asleep or waking, and the render itself wakes it.
    public var cannotReach: MediaBlocker? {
        guard let comfy = check("media.comfy") else { return nil }
        switch self.comfy {
        case .refused, .loopbackOnly, .notComfy, .unresolved:
            return MediaBlocker(
                checkID: comfy.id, sentence: MediaReading.comfyDetail(comfy, endpoint: endpoint),
                fix: comfy.fix)
        case .answering, .starting, .timedOut:
            return nil
        }
    }

    /// The same for one picture engine: a missing node blocks it, and so does a missing file of its
    /// own, which another engine's missing files do not.
    public func image(_ engine: ImageGenEngine) -> MediaBlocker? {
        guard isAnswering else { return nil }
        let spec = MediaRequirements.image(engine)
        if let nodes = check("media.image.nodes"), nodes.state == .todo,
            let missing = nodes.facts["missing"]?.split(separator: ",").map(String.init)
        {
            let mine = spec.nodes.map(\.classType).filter(missing.contains)
            if !mine.isEmpty {
                return MediaBlocker(
                    checkID: nodes.id, sentence: MediaReading.nodesSentence(missing: mine, nodes: nodes),
                    fix: nodes.fix)
            }
        }
        let gone = imageFilesMissing(for: spec)
        if !gone.isEmpty {
            return MediaBlocker(
                checkID: "media.image.models", sentence: MediaReading.filesSentence(gone, lane: .pictures),
                fix: gone.compactMap { check("media.image.model.\($0.role.rawValue)")?.fix }.first)
        }
        return nil
    }

    private func imageFilesMissing(for spec: MediaLaneSpec) -> [MediaFile] {
        spec.files.filter { check("media.image.model.\($0.role.rawValue)") != nil }
    }

    private func blocker(nodes nodesID: String, models modelsID: String, lane: MediaReading.Lane)
        -> MediaBlocker?
    {
        if let nodes = check(nodesID), nodes.state == .todo,
            let missing = nodes.facts["missing"]?.split(separator: ",").map(String.init)
        {
            return MediaBlocker(
                checkID: nodes.id, sentence: MediaReading.nodesSentence(missing: missing, nodes: nodes),
                fix: nodes.fix)
        }
        if let models = check(modelsID), models.state == .todo {
            let gone = MediaRequirements.video.files.filter {
                check("media.video.model.\($0.role.rawValue)") != nil
            }
            return MediaBlocker(
                checkID: modelsID, sentence: MediaReading.filesSentence(gone, lane: lane),
                fix: models.fix)
        }
        return nil
    }

    /// The engines this machine can paint with right now, in the order they are offered.
    public var readyEngines: [ImageGenEngine] {
        guard isAnswering else { return [] }
        return ImageGenEngine.allCases.filter { image($0) == nil }
    }

    /// The picture side's answer in its own shape, so the studios and the video board read one
    /// verdict rather than two probes that could disagree.
    public func health(running: Int? = nil) -> ImageGenHealth {
        guard isAnswering else {
            return ImageGenHealth(reachable: false, missingModels: [], version: nil, running: running)
        }
        let listed = check("media.image.models")?.state != .blocked
        let missing = ImageGenModelFile.all.filter { file in
            guard listed else { return true }
            guard let known = MediaRequirements.file(named: file.name) else { return false }
            return check("media.image.model.\(known.role.rawValue)") != nil
        }.map(\.path)
        var version: String?
        if case .answering(let found) = comfy { version = found }
        return ImageGenHealth(
            reachable: true, missingModels: missing.sorted(), version: version, running: running)
    }
}

/// Why a lane cannot render, in Core's words, and the one thing that would change it.
public struct MediaBlocker: Sendable, Equatable {
    public let checkID: String
    public let sentence: String
    public let fix: SetupFix?
}

/// One readiness answer per machine, shared by the video board and the picture studios, held for
/// a short while so the two never disagree and a second look costs nothing. Concurrent askers share
/// the one look that is out.
public actor MediaReadiness {
    public static let shared = MediaReadiness()

    public static let lifetime: TimeInterval = 30
    public static let startingLifetime: TimeInterval = 3

    private let make: @Sendable (ForgeEndpoint) -> MediaDoctor
    private let now: @Sendable () -> Date
    private var held: [String: MediaVerdict] = [:]
    private var looking: [String: Task<MediaVerdict, Never>] = [:]

    public init(
        doctor: @escaping @Sendable (ForgeEndpoint) -> MediaDoctor = { MediaDoctor(thisMachine: MediaHost.isThisMachine($0.host), helper: ImageGenStore.helper()) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        make = doctor
        self.now = now
    }

    public func cached(for endpoint: ForgeEndpoint) -> MediaVerdict? {
        guard let verdict = held[endpoint.displayHost], fresh(verdict) else { return nil }
        return verdict
    }

    public func verdict(for endpoint: ForgeEndpoint, force: Bool = false) async -> MediaVerdict {
        let key = endpoint.displayHost
        if !force, let verdict = held[key], fresh(verdict) { return verdict }
        if let task = looking[key] { return await task.value }
        let doctor = make(endpoint)
        let moment = now()
        let task = Task { MediaVerdict(endpoint: endpoint, report: await doctor.examine(endpoint), at: moment) }
        looking[key] = task
        let verdict = await task.value
        held[key] = verdict
        looking[key] = nil
        return verdict
    }

    public func forget(_ endpoint: ForgeEndpoint? = nil) {
        guard let endpoint else {
            held.removeAll()
            return
        }
        held[endpoint.displayHost] = nil
    }

    private func fresh(_ verdict: MediaVerdict) -> Bool {
        let age = now().timeIntervalSince(verdict.at)
        return age < (verdict.isStarting ? Self.startingLifetime : Self.lifetime)
    }
}

/// Whether a host is the machine the app is running on, the one case where a refused port can be
/// told apart from a ComfyUI that listens on loopback only.
public enum MediaHost {
    public static func isThisMachine(_ host: String) -> Bool {
        let lower = host.lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(lower) { return true }
        let name = ProcessInfo.processInfo.hostName.lowercased()
        let short = name.split(separator: ".").first.map(String.init) ?? name
        let first = lower.split(separator: ".").first.map(String.init) ?? lower
        if lower == name || (first == short && !first.allSatisfy { $0.isNumber }) { return true }
        return localAddresses().contains(lower)
    }

    /// Every address an interface of this machine holds, as text, because a tailnet or LAN
    /// address typed as a host is this machine just as much as its name is.
    static func localAddresses() -> Set<String> {
        var found = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return found }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let size = socklen_t(address.pointee.sa_family == sa_family_t(AF_INET6)
                    ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
                if address.pointee.sa_family == sa_family_t(AF_INET)
                    || address.pointee.sa_family == sa_family_t(AF_INET6),
                    getnameinfo(address, size, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
                {
                    found.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased())
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return found
    }
}
