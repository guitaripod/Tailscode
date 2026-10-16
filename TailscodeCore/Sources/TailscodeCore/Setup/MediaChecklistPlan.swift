import CodingAgentKit
import Foundation

/// How the doctor's checks become one checklist for a person who came from a particular place.
///
/// The doctor reports everything it knows, lane by lane. A checklist is about one thing the person
/// wants to do, so the lane they came for is laid out file by file and everything else folds into a
/// row that says what is missing and can be skipped. Nothing here changes what is true: it orders
/// the checks, drops the ones that only repeat another, and marks the ones that are optional.
enum MediaChecklistPlan {
    enum Lane {
        case video
        case pictures
    }

    private struct Table {
        let comfy: SetupCheck
        let gpu: SetupCheck?
        let videoNodes: SetupCheck?
        let videoModels: SetupCheck?
        let videoFiles: [SetupCheck]
        let imageNodes: SetupCheck?
        let imageModels: SetupCheck?
        let imageFiles: [SetupCheck]
        let helper: SetupCheck?

        init?(_ checks: [SetupCheck]) {
            guard let comfy = checks.first(where: { $0.id == "media.comfy" }) else { return nil }
            func find(_ id: String) -> SetupCheck? { checks.first { $0.id == id } }
            self.comfy = comfy
            gpu = find("media.gpu")
            videoNodes = find("media.video.nodes")
            videoModels = find("media.video.models")
            videoFiles = checks.filter { $0.id.hasPrefix("media.video.model.") }
            imageNodes = find("media.image.nodes")
            imageModels = find("media.image.models")
            imageFiles = checks.filter { $0.id.hasPrefix("media.image.model.") }
            helper = find("media.enhancer")
        }

        var videoUsable: Bool { videoNodes?.state == .ok && videoModels?.state == .ok }

        var picturesUsable: Bool { imageNodes?.state == .ok && imageModels?.state == .ok }
    }

    static func arrange(_ checks: [SetupCheck], focus: SetupFocus?) -> [SetupCheck] {
        guard let table = Table(checks) else { return checks }
        guard table.comfy.state == .ok else { return [table.comfy] }
        let lane = required(in: table, focus: focus)
        var rows = [table.comfy]
        if let gpu = table.gpu, shows(gpu, for: lane) { rows.append(gpu) }
        let order: [Lane] = lane == .video ? [.video, .pictures] : [.pictures, .video]
        for current in order {
            rows += current == .video
                ? video(table, expanded: lane == .video) : pictures(table, expanded: lane == .pictures)
        }
        if let helper = table.helper, helper.facts["model"] != nil { rows.append(helper) }
        return annotated(rows)
    }

    private static func required(in table: Table, focus: SetupFocus?) -> Lane {
        if focus == .video { return .video }
        if focus == .pictures { return .pictures }
        if table.videoUsable { return .video }
        if table.picturesUsable { return .pictures }
        guard let missing = table.videoModels.flatMap({ Int64($0.facts["bytes"] ?? "") }),
            let nearest = nearestEngine(table).map(\.bytes), nearest < missing
        else { return .video }
        return .pictures
    }

    private static func shows(_ gpu: SetupCheck, for lane: Lane) -> Bool {
        lane == .video || gpu.state != .unavailable || gpu.facts["none"] != nil
    }

    private static func video(_ table: Table, expanded: Bool) -> [SetupCheck] {
        var rows: [SetupCheck] = []
        if let nodes = table.videoNodes, expanded || nodes.state != .ok {
            rows.append(expanded ? nodes : optional(nodes))
        }
        guard let models = table.videoModels else { return rows }
        if expanded, models.state != .ok, !table.videoFiles.isEmpty { return rows + table.videoFiles }
        return rows + [expanded ? models : optional(models)]
    }

    private static func pictures(_ table: Table, expanded: Bool) -> [SetupCheck] {
        var rows: [SetupCheck] = []
        if let nodes = table.imageNodes, expanded || nodes.state != .ok {
            rows.append(expanded ? nodes : optional(nodes))
        }
        guard let models = table.imageModels else { return rows }
        guard expanded else { return rows + [optional(models)] }
        if models.state == .ok { return rows + [models] + table.imageFiles }
        guard !table.imageFiles.isEmpty else { return rows + [models] }
        let chosen = nearestEngine(table)?.roles ?? []
        let first = table.imageFiles.filter { chosen.contains($0.facts["role"] ?? "") }
        let rest = table.imageFiles.filter { !chosen.contains($0.facts["role"] ?? "") }.map(optional)
        return rows + first + rest
    }

    private static func nearestEngine(_ table: Table) -> (bytes: Int64, roles: Set<String>)? {
        let present = Dictionary(
            table.imageFiles.compactMap { check in
                check.facts["role"].map { ($0, Int64(check.facts["bytes"] ?? "") ?? 0) }
            }, uniquingKeysWith: { first, _ in first })
        guard !present.isEmpty else { return nil }
        let candidates = ImageGenEngine.allCases.map { engine -> (bytes: Int64, roles: Set<String>) in
            let roles = Set(MediaRequirements.image(engine).files.map(\.role.rawValue)).intersection(present.keys)
            return (roles.reduce(Int64(0)) { $0 + (present[$1] ?? 0) }, roles)
        }
        return candidates.filter { !$0.roles.isEmpty }.min { $0.bytes < $1.bytes }
    }

    private static func optional(_ check: SetupCheck) -> SetupCheck {
        guard check.state != .ok else { return check }
        var marked = check
        marked.facts["optional"] = "1"
        return marked
    }

    private static let qwenRoles: Set<String> = [
        MediaRole.qwenModel, .qwenTurboModel, .qwenEncoder, .qwenVAE,
    ].reduce(into: Set<String>()) { $0.insert($1.rawValue) }

    private static let gated: [MediaRepository] = [.ltx, .klein]

    private static func annotated(_ checks: [SetupCheck]) -> [SetupCheck] {
        var rows = checks
        var noted = false
        var told: Set<String> = []
        for index in rows.indices {
            if !noted, isQwen(rows[index]) {
                rows[index].facts["note"] = "qwen"
                noted = true
            }
            guard let command = rows[index].fix?.command else { continue }
            if let repository = gated.first(where: { command.contains($0.id) && !told.contains($0.id) }) {
                rows[index].facts["gate"] = repository.id
                told.insert(repository.id)
            }
        }
        return rows
    }

    private static func isQwen(_ check: SetupCheck) -> Bool {
        if let role = check.facts["role"] { return qwenRoles.contains(role) }
        guard check.id == "media.image.models" else { return false }
        let engines = (check.facts["engines"] ?? "").split(separator: ",").map(String.init)
        if engines.contains(ImageGenEngine.quality.rawValue) || engines.contains(ImageGenEngine.turbo.rawValue) {
            return true
        }
        return check.fix?.command?.contains(MediaRepository.qwenImage.id) == true
    }
}
