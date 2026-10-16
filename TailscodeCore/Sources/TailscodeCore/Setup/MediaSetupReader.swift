import CodingAgentKit
import Foundation

/// The ids `MediaDoctor` reports and the facts each carries, written in the person's language: the
/// one place the words of an images-and-video checklist live. `MediaReading` asks this reader for
/// the line a row wears, so the checklist, the video board and a refusal before a render can never
/// say two things.
///
/// `arrange` is where the person's way in shapes the list. A lane that is not the one asked about
/// collapses into a single optional row, and an optional row never holds the checklist back.
struct MediaSetupReader: SetupCapabilityReader {
    let capability = SetupCapability.media

    var name: String { Localized.text("Images and video") }
    var setUpLabel: String { Localized.text("Set up") }
    var readyHeadline: String { Localized.text("Images and video are ready") }
    var readyActionLabel: String { Localized.text("Done") }
    var addTitle: String? { Localized.text("Add image and video generation") }
    var addLine: String? { Localized.text("Pictures and clips made on a machine with a graphics card.") }

    func readyHeadline(rows: [SetupRow], focus: SetupFocus?) -> String {
        if focus == .video { return Localized.text("Video is ready") }
        if focus == .pictures { return Localized.text("Pictures are ready") }
        let videoWaits = rows.contains { $0.id.hasPrefix("media.video.") && $0.state != .done }
        let picturesWait = rows.contains { $0.id.hasPrefix("media.image.") && $0.state != .done }
        if videoWaits && !picturesWait { return Localized.text("Pictures are ready") }
        if picturesWait && !videoWaits { return Localized.text("Video is ready") }
        return readyHeadline
    }

    func readyActionLabel(focus: SetupFocus?) -> String {
        if focus == .video { return Localized.text("Render") }
        if focus == .pictures { return Localized.text("Open the studio") }
        return readyActionLabel
    }

    func headline(blocking rows: [SetupRow], focus: SetupFocus?) -> String? {
        guard let first = rows.first else { return nil }
        if first.id == "media.comfy" {
            return first.state == .working
                ? Localized.text("ComfyUI is starting") : Localized.text("ComfyUI is not answering")
        }
        let count = rows.count
        let shown = SetupFormat.number(Double(count), locale: .current)
        if focus == .video {
            return count == 1 ? Localized.text("Video needs one thing") : Localized.text("Video needs %@ things", shown)
        }
        if focus == .pictures {
            return count == 1
                ? Localized.text("Pictures need one thing") : Localized.text("Pictures need %@ things", shown)
        }
        return nil
    }

    func arrange(_ checks: [SetupCheck], focus: SetupFocus?) -> [SetupCheck] {
        MediaChecklistPlan.arrange(checks, focus: focus)
    }

    func place(of target: SetupTarget) -> SetupPlace? {
        guard let endpoint = target.forgeEndpoint else { return nil }
        return SetupPlace(
            line: Localized.text("ComfyUI at %@", endpoint.displayHost), changeLabel: Localized.text("Change"))
    }

    func title(of check: SetupCheck) -> String? {
        if let role = check.facts["role"].flatMap(MediaRole.init(rawValue:)) { return role.title }
        switch check.id {
        case "media.comfy": return Localized.text("ComfyUI")
        case "media.gpu": return Localized.text("Graphics card")
        case "media.video.nodes": return Localized.text("Video nodes")
        case "media.video.models": return Localized.text("Video models")
        case "media.image.nodes": return Localized.text("Picture nodes")
        case "media.image.models": return Localized.text("Picture models")
        case "media.enhancer": return Localized.text("Prompt helper")
        default: return nil
        }
    }

    func line(of check: SetupCheck, locale: Locale) -> String? {
        guard let words = plainLine(of: check) else { return nil }
        var line = words
        if check.facts["note"] == "qwen" {
            let note = check.facts["role"] == nil
                ? Localized.text("The Qwen engines are for personal and research use only")
                : Localized.text("For personal and research use only")
            line = [line, note].joined(separator: " · ")
        }
        return check.facts["optional"] == nil ? line : Localized.text("Optional · %@", line)
    }

    func impossibility(of check: SetupCheck, locale: Locale) -> String? {
        check.id == "media.gpu" ? Localized.text("ComfyUI found no graphics card to paint with") : nil
    }

    func fixReason(of fix: SetupFix, in check: SetupCheck) -> String? {
        switch fix.id {
        case "media.start":
            return Localized.text(
                "ComfyUI has no sign-in, so this starts it for this machine and its Tailscale address only, never for every network it is on. If Tailscale has no address there, the command starts nothing and says so."
            )
        case "media.update":
            let need = check.facts["needVersion"] ?? MediaRequirements.comfyUITag
            return Localized.text("These nodes ship with ComfyUI %@ and later", need)
        default:
            guard fix.id.hasPrefix("media.fetch.") else { return nil }
            let resume = Localized.text("An interrupted download resumes when the command is run again.")
            guard let repository = check.facts["gate"].flatMap(Self.repository(named:)) else { return resume }
            return Localized.text(
                "%1$@ is gated on Hugging Face. Accept its licence at %2$@ while signed in, then run %3$@ once on that machine. %4$@",
                Self.title(of: repository), Self.address(of: repository), MediaCommands.signIn, resume)
        }
    }

    private func plainLine(of check: SetupCheck) -> String? {
        switch check.id {
        case "media.comfy": return comfy(check)
        case "media.gpu": return gpu(check)
        case "media.video.nodes", "media.image.nodes": return nodes(check)
        case "media.video.models": return models(check, lane: .video)
        case "media.image.models": return models(check, lane: .pictures)
        case "media.enhancer": return enhancer(check)
        default: return check.facts["role"] == nil ? nil : file(check)
        }
    }

    private func comfy(_ check: SetupCheck) -> String {
        let host = check.facts["host"] ?? ""
        let port = check.facts["port"].flatMap(Int.init) ?? ForgeEndpoint.defaultPort
        return MediaReading.comfyDetail(check, endpoint: ForgeEndpoint(host: host, port: port))
    }

    private func gpu(_ check: SetupCheck) -> String {
        let need = Int(check.facts["needMB"] ?? "") ?? MediaRequirements.videoVRAMMB
        if check.state == .blocked { return Localized.text("Waiting for ComfyUI to answer") }
        if check.facts["none"] != nil { return Localized.text("ComfyUI found no graphics card to paint with") }
        let name = check.facts["name"] ?? ""
        let total = Int(check.facts["totalMB"] ?? "") ?? 0
        if check.state == .ok { return Localized.text("%@ · %@ of video memory", name, MediaReading.memory(total)) }
        return Localized.text(
            "The video model needs about %@ of video memory; this card, %@, has %@", MediaReading.memory(need),
            name, MediaReading.memory(total))
    }

    private func nodes(_ check: SetupCheck) -> String {
        switch check.state {
        case .blocked:
            return check.facts["phase"] == "unreadable"
                ? Localized.text("ComfyUI would not list its nodes") : Localized.text("Waiting for ComfyUI to answer")
        case .ok:
            let count =
                check.id == "media.video.nodes"
                ? MediaRequirements.video.nodes.count : MediaRequirements.imageNodes.count
            return Localized.text("All %@ node types are in this ComfyUI", "\(count)")
        default:
            let missing = (check.facts["missing"] ?? "").split(separator: ",").map(String.init)
            return MediaReading.nodesSentence(missing: missing, nodes: check)
        }
    }

    private func models(_ check: SetupCheck, lane: MediaReading.Lane) -> String {
        let total = Int64(check.facts["bytes"] ?? "") ?? 0
        switch check.state {
        case .blocked:
            return Localized.text("Waiting for ComfyUI; the files add up to %@", MediaReading.size(total))
        case .ok:
            if let engines = check.facts["engines"] {
                let labels = engines.split(separator: ",").compactMap { ImageGenEngine(rawValue: String($0))?.label }
                return Localized.text("Ready: %@", labels.joined(separator: ", "))
            }
            let count = lane == .video ? MediaRequirements.video.files.count : MediaRequirements.imageFiles.count
            return Localized.text("All %@ files are there", "\(count)")
        default:
            let roles = (check.facts["missing"] ?? "").split(separator: ",").compactMap { MediaRole(rawValue: String($0)) }
            return MediaReading.filesSentence(roles.map(MediaRequirements.file), lane: lane)
        }
    }

    private func file(_ check: SetupCheck) -> String {
        let bytes = Int64(check.facts["bytes"] ?? "") ?? 0
        let name = check.facts["name"] ?? ""
        if check.facts["misplaced"] != nil {
            return Localized.text(
                "%@ is in a subfolder; ComfyUI needs it directly in %@", name, check.facts["folder"] ?? "")
        }
        var parts = [MediaReading.size(bytes), name]
        if check.facts["unpublished"] != nil { parts.append(Localized.text("not published anywhere yet")) }
        return parts.joined(separator: " · ")
    }

    private func enhancer(_ check: SetupCheck) -> String {
        guard let model = check.facts["model"] else {
            return Localized.text("None found. Optional: pictures and video work without it")
        }
        return Localized.text("Rewrites your words with %@", model)
    }

    static func repository(named id: String) -> MediaRepository? {
        [MediaRepository.ltx, .klein, .qwenImage].first { $0.id == id }
    }

    private static func title(of repository: MediaRepository) -> String {
        repository == .klein ? Localized.text("FLUX Klein") : Localized.text("LTX-2.5")
    }

    private static func address(of repository: MediaRepository) -> String {
        repository.url.replacingOccurrences(of: "https://", with: "")
    }
}
