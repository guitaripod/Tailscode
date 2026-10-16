import CodingAgentKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct MediaAnswer: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum MediaTransportError: Error, Sendable, Equatable {
    case timedOut
    case refused
    case unreachable
}

/// Everything the doctor asks of the network, as values a test can replace: one GET, one port
/// question, and — only on a machine that is itself the renderer — whether something answers on the
/// loopback address, which is how "not running" is told from "running for nobody else".
public struct MediaTransport: Sendable {
    public var get: @Sendable (URL, TimeInterval) async throws -> MediaAnswer
    public var reach: @Sendable (ForgeEndpoint) async -> PortReachability.Verdict
    public var reachLoopback: (@Sendable (Int) async -> Bool)?

    public init(
        get: @escaping @Sendable (URL, TimeInterval) async throws -> MediaAnswer,
        reach: @escaping @Sendable (ForgeEndpoint) async -> PortReachability.Verdict,
        reachLoopback: (@Sendable (Int) async -> Bool)? = nil
    ) {
        self.get = get
        self.reach = reach
        self.reachLoopback = reachLoopback
    }

    /// A request given a hard deadline of its own: the system's timeout counts the gaps between
    /// packets rather than the whole wait, and a machine that is off the tailnet leaves a connect
    /// attempt hanging for minutes, which would hold every look at the renderer with it.
    private static func fetch(_ url: URL, within timeout: TimeInterval) async throws -> MediaAnswer {
        try await withThrowingTaskGroup(of: MediaAnswer.self) { group in
            group.addTask {
                var request = URLRequest(url: url, timeoutInterval: timeout)
                request.httpMethod = "GET"
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    return MediaAnswer(
                        status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
                } catch let error as URLError {
                    switch error.code {
                    case .timedOut: throw MediaTransportError.timedOut
                    case .cannotConnectToHost: throw MediaTransportError.refused
                    default: throw MediaTransportError.unreachable
                    }
                } catch {
                    throw MediaTransportError.unreachable
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MediaTransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MediaTransportError.unreachable }
            return first
        }
    }

    public static let live = MediaTransport(
        get: { url, timeout in try await fetch(url, within: timeout) },
        reach: { endpoint in await endpoint.reach() },
        reachLoopback: { port in
            await PortReachability.check(
                host: "127.0.0.1", port: UInt16(clamping: port), timeout: .seconds(2)) == .listening
        })
}

/// What ComfyUI said when asked, reduced to what the checks need.
struct MediaMachine: Sendable, Equatable {
    var version: String?
    var accelerator: Accelerator?
    var arguments: [String]

    struct Accelerator: Sendable, Equatable {
        var name: String
        var type: String
        var totalMB: Int
        var freeMB: Int
    }

    static func read(_ body: Data) -> MediaMachine? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let system = object["system"] as? [String: Any]
        else { return nil }
        let devices = (object["devices"] as? [[String: Any]]) ?? []
        let first = devices.first
        var accelerator: Accelerator?
        if let first {
            accelerator = Accelerator(
                name: first["name"] as? String ?? "",
                type: first["type"] as? String ?? "",
                totalMB: megabytes(first["vram_total"]), freeMB: megabytes(first["vram_free"]))
        }
        return MediaMachine(
            version: system["comfyui_version"] as? String, accelerator: accelerator,
            arguments: (system["argv"] as? [String]) ?? [])
    }

    private static func megabytes(_ value: Any?) -> Int {
        let bytes = (value as? NSNumber)?.doubleValue ?? 0
        return Int(bytes / 1_048_576)
    }

    /// Where this ComfyUI keeps its models, read from how it was started: the folder `main.py`
    /// sits in, or the base directory it was told to use. Nil when it was started by a relative
    /// path, which says nothing about where it lives.
    var modelsDirectory: String? {
        if let index = arguments.firstIndex(of: "--base-directory"), arguments.indices.contains(index + 1) {
            return arguments[index + 1] + "/models"
        }
        if let flag = arguments.first(where: { $0.hasPrefix("--base-directory=") }) {
            return String(flag.dropFirst("--base-directory=".count)) + "/models"
        }
        guard let script = arguments.first, script.hasPrefix("/"), script.hasSuffix(".py") else {
            return nil
        }
        return (script as NSString).deletingLastPathComponent + "/models"
    }

    var installDirectory: String? {
        modelsDirectory.map { ($0 as NSString).deletingLastPathComponent }
    }
}

/// Asks a ComfyUI what it has and says, as a `SetupReport` of capability `media`, what each lane
/// still needs. Check ids are stable keys and facts are names and numbers; the words are
/// `MediaReading`'s.
///
///     media.comfy        reachable, and if not, which of the five ways it is not
///     media.gpu          the card, against what the video lane measured at
///     media.video.nodes  the node classes the video graph names
///     media.video.models the five video files, then one row for each that is missing
///     media.image.nodes  the node classes of the engines the machine has the files for
///     media.image.models Quality, Turbo and Fast, then one row for each missing file
///     media.enhancer     a language model that rewrites short prompts; optional, never blocks
public struct MediaDoctor: Sendable {
    public static let slowStart: TimeInterval = 20
    public static let listing: TimeInterval = 30
    public static let helperTimeout: TimeInterval = 4

    public let transport: MediaTransport
    public let thisMachine: Bool
    public let helper: ImageGenHelper?

    public init(
        transport: MediaTransport = .live, thisMachine: Bool = false, helper: ImageGenHelper? = nil
    ) {
        self.transport = transport
        self.thisMachine = thisMachine
        self.helper = helper
    }

    public func examine(_ endpoint: ForgeEndpoint) async -> SetupReport {
        async let enhancer = enhancerCheck(near: endpoint)
        let comfy = await reach(endpoint)
        guard case .answering(let machine) = comfy.outcome else {
            return Self.report(
                comfy: comfy.check, machine: nil, listings: nil, nodes: nil, enhancer: await enhancer)
        }
        async let nodes = classes(on: endpoint)
        async let listings = models(on: endpoint)
        return Self.report(
            comfy: comfy.check, machine: machine, listings: await listings, nodes: await nodes,
            enhancer: await enhancer)
    }

    private struct Reached {
        enum Outcome { case answering(MediaMachine), notAnswering }
        var outcome: Outcome
        var check: SetupCheck
    }

    private func reach(_ endpoint: ForgeEndpoint) async -> Reached {
        let base: [String: String] = ["host": endpoint.host, "port": "\(endpoint.port)"]
        func failed(_ phase: String, fix: SetupFix? = nil) -> Reached {
            var facts = base
            facts["phase"] = phase
            return Reached(
                outcome: .notAnswering,
                check: SetupCheck(id: "media.comfy", state: .todo, facts: facts, fix: fix))
        }
        let startFix = SetupFix(
            id: "media.start", kind: .command, command: ForgeSetup.startCommand,
            reason: "ComfyUI accepts connections from other machines only when told which addresses to listen on")
        switch await transport.reach(endpoint) {
        case .nameNotResolved: return failed("unresolved")
        case .timedOut: return failed("timedOut")
        case .refused:
            if thisMachine, let loopback = transport.reachLoopback, await loopback(endpoint.port) {
                return failed("loopbackOnly", fix: startFix)
            }
            return failed("refused", fix: startFix)
        case .listening: break
        }
        guard let url = endpoint.url("/system_stats") else { return failed("unresolved") }
        do {
            let answer = try await transport.get(url, Self.slowStart)
            if (502...504).contains(answer.status) { return starting(base) }
            guard answer.status == 200, let machine = MediaMachine.read(answer.body) else {
                return failed("notComfy")
            }
            var facts = base
            if let version = machine.version { facts["version"] = version }
            return Reached(
                outcome: .answering(machine),
                check: SetupCheck(id: "media.comfy", state: .ok, facts: facts))
        } catch MediaTransportError.refused {
            return failed("refused", fix: startFix)
        } catch {
            return starting(base)
        }
    }

    private func starting(_ base: [String: String]) -> Reached {
        var facts = base
        facts["phase"] = "starting"
        return Reached(
            outcome: .notAnswering,
            check: SetupCheck(id: "media.comfy", state: .working, facts: facts))
    }

    private func classes(on endpoint: ForgeEndpoint) async -> MediaNodeListing? {
        guard let url = endpoint.url("/object_info"),
            let answer = try? await transport.get(url, Self.listing), answer.status == 200,
            let object = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any]
        else { return nil }
        return MediaNodeListing(object: object)
    }

    private func models(on endpoint: ForgeEndpoint) async -> [String: [String]]? {
        let folders = Set(MediaRequirements.allFiles.map(\.folder)).sorted()
        var found: [String: [String]] = [:]
        await withTaskGroup(of: (String, [String]?).self) { group in
            for folder in folders {
                group.addTask { (folder, await listing(of: folder, on: endpoint)) }
            }
            for await (folder, names) in group {
                if let names { found[folder] = names }
            }
        }
        return found.isEmpty ? nil : found
    }

    private func listing(of folder: String, on endpoint: ForgeEndpoint) async -> [String]? {
        if let url = endpoint.url("/models/\(folder)"),
            let answer = try? await transport.get(url, Self.listing), answer.status == 200,
            let names = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String]
        {
            return names
        }
        guard let file = MediaRequirements.allFiles.first(where: { $0.folder == folder }),
            let url = endpoint.url("/object_info/\(file.loader.node)"),
            let answer = try? await transport.get(url, Self.listing), answer.status == 200,
            let object = (try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any]
        else { return nil }
        return MediaNodeListing(object: object).choices(node: file.loader.node, field: file.loader.field)
    }

    private func enhancerCheck(near endpoint: ForgeEndpoint) async -> SetupCheck {
        var addresses: [String] = []
        if let helper, helper.enabled { addresses.append(helper.address) }
        for port in ImageGenHelperFinder.ports {
            let address = "http://\(endpoint.host):\(port)"
            if !addresses.contains(address) { addresses.append(address) }
        }
        var servers: [(Int, ImageGenHelperServer)] = []
        await withTaskGroup(of: (Int, ImageGenHelperServer?).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask { (index, await server(at: address)) }
            }
            for await (index, server) in group {
                if let server, !server.models.isEmpty { servers.append((index, server)) }
            }
        }
        let ordered = servers.sorted { $0.0 < $1.0 }.map(\.1)
        guard let chosen = ImageGenHelperFinder.preferred(across: ordered) else {
            return SetupCheck(id: "media.enhancer", state: .ok, facts: ["absent": "1"])
        }
        return SetupCheck(
            id: "media.enhancer", state: .ok,
            facts: ["model": chosen.model, "address": chosen.displayHost])
    }

    private func server(at address: String) async -> ImageGenHelperServer? {
        guard let url = URL(string: address + "/v1/models"),
            let answer = try? await transport.get(url, Self.helperTimeout), answer.status == 200
        else { return nil }
        return ImageGenHelperFinder.read(listing: answer.body, address: address)
    }
}

/// `/object_info` read for the two things asked of it: which node classes exist, and which
/// choices a loader offers.
struct MediaNodeListing: Sendable, Equatable {
    let classes: Set<String>
    private let choicesByNode: [String: [String: [String]]]

    init(object: [String: Any]) {
        classes = Set(object.keys)
        var choices: [String: [String: [String]]] = [:]
        for (node, value) in object {
            guard let required = ((value as? [String: Any])?["input"] as? [String: Any])?["required"]
                as? [String: Any]
            else { continue }
            for (field, spec) in required {
                guard let names = Self.options(of: spec) else { continue }
                choices[node, default: [:]][field] = names
            }
        }
        choicesByNode = choices
    }

    func choices(node: String, field: String) -> [String]? {
        choicesByNode[node]?[field]
    }

    private static func options(of spec: Any) -> [String]? {
        guard let list = spec as? [Any], let first = list.first else { return nil }
        if let names = first as? [String] { return names }
        guard first as? String == "COMBO", list.count > 1,
            let detail = list[1] as? [String: Any], let names = detail["options"] as? [String]
        else { return nil }
        return names
    }
}

extension MediaDoctor {
    struct Presence: Sendable {
        var present: Bool
        var misplaced: Bool
    }

    static func presence(of file: MediaFile, in listings: [String: [String]]?) -> Presence? {
        guard let names = listings?[file.folder] else { return nil }
        if names.contains(file.name) { return Presence(present: true, misplaced: false) }
        let elsewhere = names.contains { ($0 as NSString).lastPathComponent == file.name }
        return Presence(present: false, misplaced: elsewhere)
    }

    static func report(
        comfy: SetupCheck, machine: MediaMachine?, listings: [String: [String]]?,
        nodes: MediaNodeListing?, enhancer: SetupCheck
    ) -> SetupReport {
        let answering = comfy.state == .ok
        let models = machine?.modelsDirectory ?? MediaCommands.defaultModels
        var checks = [comfy]
        checks.append(gpu(machine: machine, answering: answering))
        let videoLanes: [(ImageGenEngine?, MediaLaneSpec)] = [(nil, MediaRequirements.video)]
        let videoNodes = nodeCheck(
            id: "media.video.nodes", lanes: videoLanes, nodes: nodes,
            machine: machine, answering: answering)
        checks.append(videoNodes)
        let video = videoModels(listings: listings, models: models, answering: answering)
        checks.append(contentsOf: video.checks)
        let imageLanes = imageEngines(listings: listings)
        let considered: [(ImageGenEngine?, MediaLaneSpec)] = (imageLanes.installed.isEmpty
            ? ImageGenEngine.allCases : imageLanes.installed).map { ($0, MediaRequirements.image($0)) }
        checks.append(
            nodeCheck(
                id: "media.image.nodes", lanes: considered, nodes: nodes, machine: machine,
                answering: answering))
        let images = imageModels(
            listings: listings, installed: imageLanes.installed, models: models, answering: answering)
        checks.append(contentsOf: images)
        checks.append(enhancer)
        let accelerator = machine?.accelerator
        let available = accelerator.map { $0.type != "cpu" } ?? true
        let videoUsable = video.complete && videoNodes.state == .ok
        let imageNodes = checks.first { $0.id == "media.image.nodes" }
        let imageUsable = !imageLanes.installed.isEmpty && imageNodes?.state == .ok
        return SetupReport(
            capability: SetupCapability.media, available: available,
            ready: answering && available && (videoUsable || imageUsable), checks: checks)
    }

    private static func gpu(machine: MediaMachine?, answering: Bool) -> SetupCheck {
        let need = MediaRequirements.videoVRAMMB
        guard answering else {
            return SetupCheck(
                id: "media.gpu", state: .blocked, facts: ["after": "media.comfy", "needMB": "\(need)"])
        }
        guard let card = machine?.accelerator else {
            return SetupCheck(
                id: "media.gpu", state: .unavailable, facts: ["none": "1", "needMB": "\(need)"])
        }
        var facts = [
            "name": card.name, "type": card.type, "totalMB": "\(card.totalMB)",
            "freeMB": "\(card.freeMB)", "needMB": "\(need)",
        ]
        if card.type == "cpu" {
            facts["none"] = "1"
            return SetupCheck(id: "media.gpu", state: .unavailable, facts: facts)
        }
        return SetupCheck(
            id: "media.gpu", state: card.totalMB >= need ? .ok : .unavailable, facts: facts)
    }

    static func nodeCheck(
        id: String, lanes: [(ImageGenEngine?, MediaLaneSpec)], nodes: MediaNodeListing?,
        machine: MediaMachine?, answering: Bool
    ) -> SetupCheck {
        guard answering else {
            return SetupCheck(id: id, state: .blocked, facts: ["after": "media.comfy"])
        }
        guard let nodes else {
            return SetupCheck(id: id, state: .blocked, facts: ["phase": "unreadable"])
        }
        var missing: [String] = []
        var affected: [String] = []
        var need = "0"
        for (engine, spec) in lanes {
            let gone = spec.nodes.map(\.classType).filter { !nodes.classes.contains($0) }
            guard !gone.isEmpty else { continue }
            missing.append(contentsOf: gone.filter { !missing.contains($0) })
            if let engine { affected.append(engine.rawValue) }
            if MediaVersion(spec.minimumComfyUI) > MediaVersion(need) { need = spec.minimumComfyUI }
        }
        var facts: [String: String] = [:]
        if let version = machine?.version { facts["version"] = version }
        guard !missing.isEmpty else { return SetupCheck(id: id, state: .ok, facts: facts) }
        facts["missing"] = missing.sorted().joined(separator: ",")
        facts["needVersion"] = need
        if !affected.isEmpty { facts["engines"] = affected.joined(separator: ",") }
        let directory = machine?.installDirectory ?? "~/comfyui/ComfyUI"
        return SetupCheck(
            id: id, state: .todo, facts: facts,
            fix: SetupFix(
                id: "media.update", kind: .command, command: MediaCommands.update(into: directory),
                reason: "These nodes ship with ComfyUI \(need) and later"))
    }

    private static func missingFacts(_ files: [MediaFile], misplaced: [MediaFile]) -> [String: String] {
        var facts: [String: String] = [:]
        if !files.isEmpty { facts["missing"] = files.map(\.role.rawValue).joined(separator: ",") }
        facts["bytes"] = "\(files.reduce(Int64(0)) { $0 + $1.bytes })"
        if !misplaced.isEmpty {
            facts["misplaced"] = misplaced.map(\.role.rawValue).joined(separator: ",")
        }
        let hidden = files.filter { !$0.isPublished }
        if !hidden.isEmpty { facts["unpublished"] = hidden.map(\.role.rawValue).joined(separator: ",") }
        return facts
    }

    private static func fetchFix(
        id: String, files: [MediaFile], models: String, all: Bool
    ) -> SetupFix? {
        let published = files.filter(\.isPublished)
        guard let command = all
            ? MediaCommands.fetchAll(published, into: models)
            : MediaCommands.fetch(published, into: models)
        else { return nil }
        let gated = published.contains { $0.repository?.gated == true }
        let bytes = published.reduce(Int64(0)) { $0 + $1.bytes }
        return SetupFix(
            id: id, kind: .command, command: command,
            reason: gated
                ? "The licence must be accepted on the repository's page and `hf auth login` run once; an interrupted download resumes"
                : "An interrupted download resumes when the command is run again",
            bytes: bytes)
    }

    private struct VideoModels {
        var checks: [SetupCheck]
        var complete: Bool
    }

    private static func videoModels(
        listings: [String: [String]]?, models: String, answering: Bool
    ) -> VideoModels {
        let spec = MediaRequirements.video
        guard answering, listings != nil else {
            return VideoModels(
                checks: [
                    SetupCheck(
                        id: "media.video.models", state: .blocked,
                        facts: [
                            "after": answering ? "media.models" : "media.comfy",
                            "bytes": "\(spec.totalBytes)",
                        ])
                ], complete: false)
        }
        var gone: [MediaFile] = []
        var moved: [MediaFile] = []
        for file in spec.files {
            guard let found = presence(of: file, in: listings) else { continue }
            if !found.present { gone.append(file) }
            if found.misplaced { moved.append(file) }
        }
        var facts = missingFacts(gone, misplaced: moved)
        facts["models"] = models
        var rows: [SetupCheck] = []
        let aggregate = SetupCheck(
            id: "media.video.models", state: gone.isEmpty ? .ok : .todo, facts: facts,
            fix: gone.isEmpty
                ? nil : fetchFix(id: "media.fetch.video", files: gone, models: models, all: true))
        rows.append(aggregate)
        rows.append(contentsOf: gone.map { fileRow(prefix: "media.video.model", file: $0, models: models, moved: moved, optional: false) })
        return VideoModels(checks: rows, complete: gone.isEmpty)
    }

    private static func fileRow(
        prefix: String, file: MediaFile, models: String, moved: [MediaFile], optional: Bool
    ) -> SetupCheck {
        var facts = [
            "role": file.role.rawValue, "name": file.name, "folder": file.folder,
            "bytes": "\(file.bytes)",
        ]
        if let repository = file.repository {
            facts["repository"] = repository.id
            facts["license"] = repository.license
            if repository.gated { facts["gated"] = "1" }
        } else {
            facts["unpublished"] = "1"
        }
        if moved.contains(file) { facts["misplaced"] = "1" }
        if optional { facts["optional"] = "1" }
        return SetupCheck(
            id: "\(prefix).\(file.role.rawValue)", state: .todo, facts: facts,
            fix: moved.contains(file)
                ? nil
                : fetchFix(id: "media.fetch.\(file.role.rawValue)", files: [file], models: models, all: false))
    }

    private struct Engines {
        var installed: [ImageGenEngine]
    }

    private static func imageEngines(listings: [String: [String]]?) -> Engines {
        guard listings != nil else { return Engines(installed: []) }
        let installed = ImageGenEngine.allCases.filter { engine in
            MediaRequirements.image(engine).files.allSatisfy {
                presence(of: $0, in: listings)?.present == true
            }
        }
        return Engines(installed: installed)
    }

    private static func imageModels(
        listings: [String: [String]]?, installed: [ImageGenEngine], models: String, answering: Bool
    ) -> [SetupCheck] {
        let all = MediaRequirements.imageFiles
        let total = all.reduce(Int64(0)) { $0 + $1.bytes }
        guard answering, listings != nil else {
            return [
                SetupCheck(
                    id: "media.image.models", state: .blocked,
                    facts: [
                        "after": answering ? "media.models" : "media.comfy", "bytes": "\(total)",
                    ])
            ]
        }
        let wanted = ImageGenEngine.allCases.filter { !installed.contains($0) }
        var seen = Set<MediaRole>()
        let gone = wanted.flatMap { MediaRequirements.image($0).files }
            .filter { file in
                seen.insert(file.role).inserted && presence(of: file, in: listings)?.present != true
            }
        let moved = gone.filter { presence(of: $0, in: listings)?.misplaced == true }
        var facts = missingFacts(gone, misplaced: moved)
        facts["models"] = models
        if !installed.isEmpty { facts["engines"] = installed.map(\.rawValue).joined(separator: ",") }
        let optional = !installed.isEmpty
        let first = wanted.first.map { engine in
            MediaRequirements.image(engine).files.filter { file in gone.contains(file) }
        } ?? []
        var rows = [
            SetupCheck(
                id: "media.image.models", state: installed.isEmpty ? .todo : .ok, facts: facts,
                fix: installed.isEmpty
                    ? fetchFix(id: "media.fetch.image", files: first, models: models, all: true) : nil)
        ]
        rows.append(
            contentsOf: gone.map {
                fileRow(prefix: "media.image.model", file: $0, models: models, moved: moved, optional: optional)
            })
        return rows
    }
}

/// A ComfyUI version as numbers, so "0.9" is older than "0.41".
struct MediaVersion: Comparable, Sendable {
    let parts: [Int]

    init(_ text: String) {
        let plain = text.hasPrefix("v") ? String(text.dropFirst()) : text
        parts = plain.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func < (lhs: MediaVersion, rhs: MediaVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
