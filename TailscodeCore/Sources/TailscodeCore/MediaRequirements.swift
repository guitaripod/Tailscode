import Foundation

/// Where a file a lane needs can be had by somebody who is not the author.
public enum MediaFileSource: Sendable, Equatable, Hashable {
    case huggingFace(MediaRepository, path: String)
    case unpublished
}

/// A Hugging Face repository the catalog downloads from, pinned to the commit the sizes and
/// paths were verified against so a command copied today is the command that was checked.
public struct MediaRepository: Sendable, Equatable, Hashable {
    public let id: String
    public let revision: String
    public let gated: Bool
    public let license: String

    public var url: String { "https://huggingface.co/\(id)" }

    public static let ltx = MediaRepository(
        id: "Lightricks/LTX-2.5", revision: "49b093a39c19169a8a81721dcc541e07e945232f",
        gated: true, license: "ltx-2.x-community-license-agreement")

    public static let qwenImage = MediaRepository(
        id: "Comfy-Org/Qwen-Image-2.1", revision: "a8342359c61979b06a8dafb1a47991fe1f30e994",
        gated: false, license: "qwen-research")

    public static let klein = MediaRepository(
        id: "black-forest-labs/flux-3-image-klein-comfy",
        revision: "5c9b714851dc072b04a23ef6d2d36421f5ccb3a0", gated: true,
        license: "flux-kommunity-license")
}

/// What a file is for, as a stable key. The key is what a report's facts and a fix's id carry; the
/// words are Core's.
public enum MediaRole: String, Sendable, CaseIterable, Hashable {
    case videoModel
    case videoEncoder
    case videoVAE
    case audioVAE
    case videoUpscaler
    case qwenModel
    case qwenTurboModel
    case qwenEncoder
    case qwenVAE
    case kleinModel
    case kleinEncoder
    case kleinVAE

    /// The file as a sentence names it: "The video model", never "UNETLoader".
    public var title: String {
        switch self {
        case .videoModel: return Localized.text("The video model")
        case .videoEncoder: return Localized.text("The video text encoder")
        case .videoVAE: return Localized.text("The video decoder")
        case .audioVAE: return Localized.text("The audio decoder")
        case .videoUpscaler: return Localized.text("The video upscaler")
        case .qwenModel: return Localized.text("The Qwen picture model")
        case .qwenTurboModel: return Localized.text("The Qwen Turbo picture model")
        case .qwenEncoder: return Localized.text("The Qwen text encoder")
        case .qwenVAE: return Localized.text("The Qwen picture decoder")
        case .kleinModel: return Localized.text("The Klein picture model")
        case .kleinEncoder: return Localized.text("The Klein text encoder")
        case .kleinVAE: return Localized.text("The Klein picture decoder")
        }
    }
}

/// One model file a lane submits by name: where ComfyUI looks for it, how big it is, and where a
/// stranger can get it.
public struct MediaFile: Sendable, Equatable, Hashable, Identifiable {
    public let role: MediaRole
    public let folder: String
    public let name: String
    public let bytes: Int64
    public let source: MediaFileSource

    public var id: String { role.rawValue }

    public var path: String { folder + "/" + name }

    public var isPublished: Bool { source != .unpublished }

    public var repository: MediaRepository? {
        guard case .huggingFace(let repository, _) = source else { return nil }
        return repository
    }

    public var repositoryPath: String? {
        guard case .huggingFace(_, let path) = source else { return nil }
        return path
    }

    /// The loader node that lists this folder, which is how a ComfyUI too old to answer
    /// `/models/<folder>` is asked instead.
    public var loader: (node: String, field: String) {
        switch folder {
        case "diffusion_models": return ("UNETLoader", "unet_name")
        case "text_encoders": return ("CLIPLoader", "clip_name")
        case "vae": return ("VAELoader", "vae_name")
        default: return ("LatentUpscaleModelLoader", "model_name")
        }
    }

    public static func hosted(
        _ role: MediaRole, folder: String, name: String, bytes: Int64, in repository: MediaRepository
    ) -> MediaFile {
        MediaFile(
            role: role, folder: folder, name: name, bytes: bytes,
            source: .huggingFace(repository, path: folder + "/" + name))
    }
}

/// A node class the lane's graph names. ComfyUI ships every one of them itself, from the version
/// that introduced it; none comes from a custom node pack.
public struct MediaNode: Sendable, Equatable, Hashable {
    public let classType: String
    public let source: MediaNodeSource
}

public enum MediaNodeSource: Sendable, Equatable, Hashable {
    case comfyUI
    case unpublished
}

/// What one lane needs on the machine that renders it.
public struct MediaLaneSpec: Sendable, Equatable {
    public let id: String
    public let files: [MediaFile]
    public let nodes: [MediaNode]
    public let minimumComfyUI: String
    public let vramMB: Int?

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// The catalog of everything the video and picture lanes submit, derived from the graphs the code
/// builds (a test pins the two together) and verified against Hugging Face on 2026-10-16.
public enum MediaRequirements {
    public static let comfyUITag = "v0.41.2"
    public static let comfyUICommit = "b53f77a74e21091cbdebfdf7b85fc80326932646"
    public static let comfyUIRepository = "https://github.com/comfyanonymous/ComfyUI.git"
    public static let comfyUIPort = ForgeEndpoint.defaultPort

    public static let videoModel = MediaFile.hosted(
        .videoModel, folder: "diffusion_models", name: ForgeModel.fileName, bytes: 42_018_190_584,
        in: .ltx)
    public static let videoEncoder = MediaFile.hosted(
        .videoEncoder, folder: "text_encoders", name: ForgeGraph.clipEncoder, bytes: 26_263_858_182,
        in: .ltx)
    public static let videoVAE = MediaFile.hosted(
        .videoVAE, folder: "vae", name: ForgeGraph.videoVAE, bytes: 1_472_223_346, in: .ltx)
    public static let audioVAE = MediaFile.hosted(
        .audioVAE, folder: "vae", name: ForgeGraph.audioVAE, bytes: 364_866_540, in: .ltx)
    public static let videoUpscaler = MediaFile.hosted(
        .videoUpscaler, folder: "latent_upscale_models", name: ForgeGraph.upscaler,
        bytes: 995_778_752, in: .ltx)

    public static let qwenModel = MediaFile.hosted(
        .qwenModel, folder: "diffusion_models", name: ImageGenModelFile.qwenDiffusion.name,
        bytes: 7_256_783_064, in: .qwenImage)
    public static let qwenTurboModel = MediaFile.hosted(
        .qwenTurboModel, folder: "diffusion_models", name: ImageGenModelFile.turboDiffusion.name,
        bytes: 14_230_280_616, in: .qwenImage)
    public static let qwenEncoder = MediaFile.hosted(
        .qwenEncoder, folder: "text_encoders", name: ImageGenModelFile.qwenText.name,
        bytes: 9_350_798_360, in: .qwenImage)
    public static let qwenVAE = MediaFile.hosted(
        .qwenVAE, folder: "vae", name: ImageGenModelFile.qwenVAE.name, bytes: 675_509_688,
        in: .qwenImage)

    public static let kleinModel = MediaFile.hosted(
        .kleinModel, folder: "diffusion_models", name: ImageGenModelFile.kleinDiffusion.name,
        bytes: 11_097_404_512, in: .klein)
    public static let kleinEncoder = MediaFile.hosted(
        .kleinEncoder, folder: "text_encoders", name: ImageGenModelFile.kleinText.name,
        bytes: 8_875_719_408, in: .klein)
    public static let kleinVAE = MediaFile.hosted(
        .kleinVAE, folder: "vae", name: ImageGenModelFile.kleinVAE.name, bytes: 336_211_292,
        in: .klein)

    public static let allFiles: [MediaFile] = [
        videoModel, videoEncoder, videoVAE, audioVAE, videoUpscaler, qwenModel, qwenTurboModel,
        qwenEncoder, qwenVAE, kleinModel, kleinEncoder, kleinVAE,
    ]

    public static func file(_ role: MediaRole) -> MediaFile {
        allFiles.first { $0.role == role } ?? videoModel
    }

    /// The measured peak, about 72 GB, of a five-second 1280 by 704 clip on the author's 96 GB card. Below it
    /// ComfyUI offloads to system memory and may be far slower or fail; nothing smaller has been
    /// measured, so the report says "needs about" and never "cannot".
    public static let videoVRAMMB = 73_728

    private static func nodes(_ classes: [String]) -> [MediaNode] {
        classes.sorted().map { MediaNode(classType: $0, source: .comfyUI) }
    }

    public static let video = MediaLaneSpec(
        id: "video",
        files: [videoModel, videoEncoder, videoVAE, audioVAE, videoUpscaler],
        nodes: nodes([
            "UNETLoader", "CLIPLoader", "VAELoader", "LatentUpscaleModelLoader", "CLIPTextEncode",
            "LTXVConditioning", "EmptyLTXVLatentVideo", "LTXVEmptyLatentAudio",
            "LTXVConcatAVLatent", "RandomNoise", "KSamplerSelect", "ManualSigmas",
            "LTXVDualCFGGuider", "SamplerCustomAdvanced", "LTXVSeparateAVLatent",
            "LTXVLatentUpsampler", "VAEDecodeTiled", "LTXVAudioVAEDecode", "CreateVideo",
            "SaveVideo", "LoadImage", "LoadVideo", "GetVideoComponents", "ImageFromBatch",
            "LTXVPreprocess", "LTXVImgToVideoInplace",
        ]),
        minimumComfyUI: "0.33.0", vramMB: videoVRAMMB)

    private static let qwenCommon = [
        "UNETLoader", "CLIPLoader", "VAELoader", "VAEDecode", "SaveImage",
        "TextEncodeQwenImage21", "QwenImage21Cache", "EmptyLatentImage", "LoadImage",
    ]

    public static let quality = MediaLaneSpec(
        id: "quality", files: [qwenModel, qwenEncoder, qwenVAE],
        nodes: nodes(qwenCommon + ["KSampler"]), minimumComfyUI: "0.37.0", vramMB: nil)

    public static let turbo = MediaLaneSpec(
        id: "turbo", files: [qwenTurboModel, qwenEncoder, qwenVAE],
        nodes: nodes(qwenCommon + ["KSamplerSelect", "ManualSigmas", "SamplerCustom"]),
        minimumComfyUI: "0.37.0", vramMB: nil)

    public static let fast = MediaLaneSpec(
        id: "fast", files: [kleinModel, kleinEncoder, kleinVAE],
        nodes: nodes([
            "UNETLoader", "CLIPLoader", "VAELoader", "VAEDecode", "SaveImage", "CLIPTextEncode",
            "ConditioningZeroOut", "KSampler", "EmptyFlux2LatentImage", "LoadImage",
            "ReferenceMultiLatent",
        ]),
        minimumComfyUI: "0.41.0", vramMB: nil)

    public static func image(_ engine: ImageGenEngine) -> MediaLaneSpec {
        switch engine {
        case .quality: return quality
        case .turbo: return turbo
        case .fast: return fast
        }
    }

    public static var imageLanes: [(engine: ImageGenEngine, spec: MediaLaneSpec)] {
        ImageGenEngine.allCases.map { ($0, image($0)) }
    }

    public static var imageFiles: [MediaFile] {
        var seen = Set<MediaRole>()
        return imageLanes.flatMap(\.spec.files).filter { seen.insert($0.role).inserted }
    }

    public static var imageNodes: [MediaNode] {
        var seen = Set<String>()
        return imageLanes.flatMap(\.spec.nodes).filter { seen.insert($0.classType).inserted }
            .sorted { $0.classType < $1.classType }
    }

    public static var publicFiles: [MediaFile] { allFiles.filter(\.isPublished) }

    public static var unpublishedFiles: [MediaFile] { allFiles.filter { !$0.isPublished } }

    public static var unpublishedNodes: [MediaNode] {
        (video.nodes + imageNodes).filter { $0.source == .unpublished }
    }

    /// The file a graph names, found by the name it submits.
    public static func file(named name: String) -> MediaFile? {
        allFiles.first { $0.name == name }
    }
}

/// The one-line commands that fetch and start what the catalog lists, in one place so the report,
/// the document and the script cannot drift.
public enum MediaCommands {
    public static let installTool = "pip install -U \"huggingface_hub[cli]\""

    public static let signIn = "hf auth login"

    /// `hf download` for the files of one repository, placed under the machine's models folder.
    /// The command resumes a half-finished download by itself when run again.
    public static func fetch(_ files: [MediaFile], into models: String) -> String? {
        guard let repository = files.first?.repository,
            files.allSatisfy({ $0.repository == repository })
        else { return nil }
        let paths = files.compactMap(\.repositoryPath).map(shellQuoted)
        return (["hf", "download", repository.id, "--revision", repository.revision]
            + paths + ["--local-dir", shellQuoted(models)]).joined(separator: " ")
    }

    /// Every missing file, one command per repository, joined so a single paste fetches them all.
    public static func fetchAll(_ files: [MediaFile], into models: String) -> String? {
        var order: [MediaRepository] = []
        for file in files {
            if let repository = file.repository, !order.contains(repository) {
                order.append(repository)
            }
        }
        let lines = order.compactMap { repository in
            fetch(files.filter { $0.repository == repository }, into: models)
        }
        return lines.isEmpty ? nil : lines.joined(separator: " && ")
    }

    public static let defaultModels = "~/comfyui/ComfyUI/models"

    public static func update(into directory: String) -> String {
        [
            "cd \(shellQuoted(directory))", "git fetch --tags", "git checkout \(MediaRequirements.comfyUITag)",
            "pip install -r requirements.txt",
        ].joined(separator: " && ")
    }

    private static func shellQuoted(_ text: String) -> String {
        let plain = text.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
