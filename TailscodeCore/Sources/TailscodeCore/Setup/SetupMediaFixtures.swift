import CodingAgentKit
import Foundation

extension SetupFixtures {
    /// The images-and-video checklist in each state a person can meet, built from the same
    /// `MediaDoctor.report` a real ComfyUI produces, so a harness, a screenshot and a test see the
    /// real rows with no machine behind them. `media` is a machine with a card and nothing installed.
    public static let mediaNames = [
        "media", "media-video", "media-pictures", "media-ready", "media-down", "media-loopback",
        "media-starting", "media-nocard", "media-smallcard",
    ]

    static func mediaSnapshot(named name: String) -> SetupSnapshot? {
        let endpoint = ForgeEndpoint(host: host)
        let target = SetupTarget.media(endpoint)
        guard let report = mediaReport(named: name, endpoint: endpoint) else { return nil }
        return SetupSnapshot(target: target, phase: .loaded, report: report)
    }

    private static var allClasses: [String: Any] {
        Dictionary(
            (MediaRequirements.video.nodes + MediaRequirements.imageNodes).map { ($0.classType, [String: Any]()) },
            uniquingKeysWith: { first, _ in first })
    }

    private static func mediaReport(named name: String, endpoint: ForgeEndpoint) -> SetupReport? {
        let base = ["host": endpoint.host, "port": "\(endpoint.port)"]
        let quiet = SetupCheck(id: "media.enhancer", state: .ok, facts: ["absent": "1"])
        func answering(card: Int = 97_887, kind: String = "cuda", have: [MediaRole]) -> SetupReport {
            var found: [String: [String]] = [:]
            for file in MediaRequirements.allFiles where have.contains(file.role) {
                found[file.folder, default: []].append(file.name)
            }
            for folder in Set(MediaRequirements.allFiles.map(\.folder)) where found[folder] == nil { found[folder] = [] }
            let machine = MediaMachine(
                version: "0.41.2",
                accelerator: MediaMachine.Accelerator(
                    name: "NVIDIA RTX PRO 6000 Blackwell", type: kind, totalMB: card, freeMB: card - 1024),
                arguments: ["/home/demo/comfyui/ComfyUI/main.py"])
            var facts = base
            facts["version"] = "0.41.2"
            return MediaDoctor.report(
                comfy: SetupCheck(id: "media.comfy", state: .ok, facts: facts), machine: machine,
                listings: found, nodes: MediaNodeListing(object: allClasses), enhancer: quiet)
        }
        func unreachable(_ phase: String, _ state: SetupState, fix: Bool) -> SetupReport {
            var facts = base
            facts["phase"] = phase
            let start = SetupFix(
                id: "media.start", kind: .command, command: ForgeSetup.startCommand,
                reason: "ComfyUI accepts connections from other machines only when told which addresses to listen on")
            return MediaDoctor.report(
                comfy: SetupCheck(id: "media.comfy", state: state, facts: facts, fix: fix ? start : nil),
                machine: nil, listings: nil, nodes: nil, enhancer: quiet)
        }
        let video = MediaRequirements.video.files.map(\.role)
        let klein = MediaRequirements.image(.fast).files.map(\.role)
        switch name {
        case "media": return answering(have: [])
        case "media-video": return answering(have: video)
        case "media-pictures": return answering(have: klein)
        case "media-ready": return answering(have: MediaRequirements.allFiles.map(\.role))
        case "media-down": return unreachable("refused", .todo, fix: true)
        case "media-loopback": return unreachable("loopbackOnly", .todo, fix: true)
        case "media-starting": return unreachable("starting", .working, fix: false)
        case "media-nocard": return answering(card: 0, kind: "cpu", have: [])
        case "media-smallcard": return answering(card: 24_564, have: video)
        default: return nil
        }
    }
}
