import CodingAgentKit
import Foundation

/// Every word the doctor's checks are shown in. A check is an id and some facts; this turns them
/// into the line a row wears, in the person's language, and into the sentence a render that cannot
/// work gives instead of a node's error.
public enum MediaReading {
    public enum Lane: Sendable {
        case video
        case pictures

        var name: String {
            switch self {
            case .video: return Localized.text("video")
            case .pictures: return Localized.text("pictures")
            }
        }
    }

    public struct Line: Sendable, Equatable {
        public let id: String
        public let state: SetupState
        public let title: String
        public let detail: String
        public let tone: ActivityTone
        public let fix: SetupFix?
        public let isOptional: Bool
    }

    public static func lines(_ verdict: MediaVerdict) -> [Line] {
        verdict.report.checks.map { line(for: $0, in: verdict) }
    }

    public static func line(for check: SetupCheck, in verdict: MediaVerdict) -> Line {
        Line(
            id: check.id, state: check.state, title: title(of: check), detail: detail(of: check, in: verdict),
            tone: tone(of: check.state), fix: check.fix, isOptional: check.facts["optional"] != nil)
    }

    private static func tone(of state: SetupState) -> ActivityTone {
        switch state {
        case .ok, .working: return .live
        case .todo, .unavailable: return .attention
        case .blocked: return .quiet
        }
    }

    static func title(of check: SetupCheck) -> String {
        if let role = check.facts["role"].flatMap(MediaRole.init(rawValue:)) { return role.title }
        switch check.id {
        case "media.comfy": return Localized.text("ComfyUI")
        case "media.gpu": return Localized.text("Graphics card")
        case "media.video.nodes": return Localized.text("Video nodes")
        case "media.video.models": return Localized.text("Video models")
        case "media.image.nodes": return Localized.text("Picture nodes")
        case "media.image.models": return Localized.text("Picture models")
        case "media.enhancer": return Localized.text("Prompt helper")
        default: return check.id
        }
    }

    static func detail(of check: SetupCheck, in verdict: MediaVerdict) -> String {
        switch check.id {
        case "media.comfy": return comfyDetail(check, endpoint: verdict.endpoint)
        case "media.gpu": return gpuDetail(check)
        case "media.video.nodes", "media.image.nodes": return nodesDetail(check)
        case "media.video.models": return modelsDetail(check, lane: .video)
        case "media.image.models": return modelsDetail(check, lane: .pictures)
        case "media.enhancer": return enhancerDetail(check)
        default:
            if check.facts["role"] != nil { return fileDetail(check) }
            return check.detail ?? check.id
        }
    }

    public static func comfyDetail(_ check: SetupCheck, endpoint: ForgeEndpoint) -> String {
        let host = endpoint.host
        if check.state == .ok {
            let answering = Localized.text("Answering on %@", "\(endpoint.port)")
            guard let version = check.facts["version"] else { return answering }
            return [answering, Localized.text("ComfyUI %@", version)].joined(separator: " · ")
        }
        switch check.facts["phase"] {
        case "starting":
            return Localized.text("ComfyUI is starting on %@; it will be ready in a minute", host)
        case "refused":
            return Localized.text(
                "Nothing is listening on %@ on %@. If ComfyUI is running there, start it with --listen so other machines can reach it.",
                "\(endpoint.port)", host)
        case "loopbackOnly":
            return Localized.text(
                "ComfyUI is running on %@ but only accepts connections from that machine: start it with --listen",
                host)
        case "timedOut":
            return ForgeEndpoint.sentence(for: .timedOut, host: host)
        case "unresolved":
            return ForgeEndpoint.sentence(for: .nameNotResolved, host: host)
        default:
            return Localized.text("Something answers on %@ but it is not ComfyUI", endpoint.displayHost)
        }
    }

    private static func gpuDetail(_ check: SetupCheck) -> String {
        let need = Int(check.facts["needMB"] ?? "") ?? MediaRequirements.videoVRAMMB
        if check.state == .blocked { return Localized.text("Waiting for ComfyUI to answer") }
        if check.facts["none"] != nil {
            return Localized.text("ComfyUI found no graphics card to paint with")
        }
        let name = check.facts["name"] ?? ""
        let total = Int(check.facts["totalMB"] ?? "") ?? 0
        if check.state == .ok {
            return Localized.text("%@ · %@ of video memory", name, memory(total))
        }
        return Localized.text(
            "The video model needs about %@ of video memory; this card, %@, has %@", memory(need),
            name, memory(total))
    }

    private static func nodesDetail(_ check: SetupCheck) -> String {
        switch check.state {
        case .blocked:
            return check.facts["phase"] == "unreadable"
                ? Localized.text("ComfyUI would not list its nodes")
                : Localized.text("Waiting for ComfyUI to answer")
        case .ok:
            let count = check.id == "media.video.nodes"
                ? MediaRequirements.video.nodes.count : MediaRequirements.imageNodes.count
            return Localized.text("All %@ node types are in this ComfyUI", "\(count)")
        default:
            let missing = (check.facts["missing"] ?? "").split(separator: ",").map(String.init)
            return nodesSentence(missing: missing, nodes: check)
        }
    }

    static func nodesSentence(missing: [String], nodes: SetupCheck) -> String {
        let shown = missing.prefix(3).joined(separator: ", ")
        let names = missing.count > 3
            ? Localized.text("%@ and %@ more", shown, "\(missing.count - 3)") : shown
        let need = nodes.facts["needVersion"] ?? MediaRequirements.comfyUITag
        if let version = nodes.facts["version"] {
            return Localized.text(
                "ComfyUI %@ lacks %@; %@ or newer has what this needs", version, names, need)
        }
        return Localized.text("This ComfyUI lacks %@; %@ or newer has what this needs", names, need)
    }

    private static func modelsDetail(_ check: SetupCheck, lane: Lane) -> String {
        let total = Int64(check.facts["bytes"] ?? "") ?? 0
        switch check.state {
        case .blocked:
            return Localized.text("Waiting for ComfyUI; the files add up to %@", size(total))
        case .ok:
            if let engines = check.facts["engines"] {
                let labels = engines.split(separator: ",").compactMap { ImageGenEngine(rawValue: String($0))?.label }
                return Localized.text("Ready: %@", labels.joined(separator: ", "))
            }
            let count = lane == .video ? MediaRequirements.video.files.count : MediaRequirements.imageFiles.count
            return Localized.text("All %@ files are there", "\(count)")
        default:
            let roles = (check.facts["missing"] ?? "").split(separator: ",")
                .compactMap { MediaRole(rawValue: String($0)) }
            return filesSentence(roles.map(MediaRequirements.file), lane: lane)
        }
    }

    static func filesSentence(_ files: [MediaFile], lane: Lane) -> String {
        guard let first = files.first else { return "" }
        if files.count == 1 {
            return Localized.text(
                "%@ is missing: %@, %@", first.role.title, size(first.bytes), first.name)
        }
        let shown = files.prefix(2).map { Localized.text("%@ (%@)", $0.role.title, size($0.bytes)) }
            .joined(separator: "; ")
        let list = files.count > 2
            ? Localized.text("%@ and %@ more", shown, "\(files.count - 2)") : shown
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        return Localized.text("Missing for %@, %@ in all: %@", lane.name, size(total), list)
    }

    private static func fileDetail(_ check: SetupCheck) -> String {
        let bytes = Int64(check.facts["bytes"] ?? "") ?? 0
        let name = check.facts["name"] ?? ""
        if check.facts["misplaced"] != nil {
            return Localized.text(
                "%@ is in a subfolder; ComfyUI needs it directly in %@", name, check.facts["folder"] ?? "")
        }
        var parts = [size(bytes), name]
        if check.facts["unpublished"] != nil {
            parts.append(Localized.text("not published anywhere yet"))
        } else if check.facts["gated"] != nil {
            parts.append(Localized.text("needs the licence accepted first"))
        }
        return parts.joined(separator: " · ")
    }

    private static func enhancerDetail(_ check: SetupCheck) -> String {
        guard let model = check.facts["model"] else {
            return Localized.text("None found. Optional: pictures and video work without it")
        }
        return Localized.text("Rewrites your words with %@", model)
    }

    public static func size(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 { return Localized.text("%@ GB", rounded(gigabytes)) }
        return Localized.text("%@ MB", String(format: "%.0f", Double(bytes) / 1_000_000))
    }

    static func memory(_ megabytes: Int) -> String {
        Localized.text("%@ GB", rounded(Double(megabytes) / 1024))
    }

    private static func rounded(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return String(format: tenths == tenths.rounded() ? "%.0f" : "%.1f", tenths)
    }

    /// The line the video board shows for the renderer: ComfyUI's own state until it answers, then
    /// the one thing the lane still needs, then nothing.
    public static func videoLine(_ verdict: MediaVerdict) -> Line? {
        guard let comfy = verdict.check("media.comfy") else { return nil }
        if comfy.state != .ok { return line(for: comfy, in: verdict) }
        guard let blocker = verdict.video else { return nil }
        let check = verdict.check(blocker.checkID) ?? comfy
        return Line(
            id: blocker.checkID, state: check.state, title: title(of: check), detail: blocker.sentence,
            tone: .attention, fix: blocker.fix, isOptional: false)
    }

    public static func imageSentence(_ verdict: MediaVerdict, engine: ImageGenEngine) -> String? {
        if let comfy = verdict.check("media.comfy"), comfy.state != .ok {
            return comfyDetail(comfy, endpoint: verdict.endpoint)
        }
        return verdict.image(engine)?.sentence
    }
}

/// The words around the doctor's rows that are not about one check.
public enum MediaWords {
    public static var groupTitle: String { Localized.text("What this machine can make") }

    public static var copyCommand: String { Localized.text("Copy the command") }

    public static var startingMark: String { Localized.text("starting") }

    public static var optionalMark: String { Localized.text("optional") }

    public static var copied: String { Localized.text("Copied — run it in a terminal.") }
}
