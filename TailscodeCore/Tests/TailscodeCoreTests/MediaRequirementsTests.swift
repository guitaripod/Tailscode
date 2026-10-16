import Foundation
import Testing

@testable import TailscodeCore

/// The catalog is only worth having if it is the graphs' own truth, so these read the graphs the
/// code builds and hold the catalog to them: every file a graph names, every node class it uses.
@Suite("Media requirements")
struct MediaRequirementsTests {
    private func classes(_ graph: [String: Any]) -> Set<String> {
        Set(graph.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String })
    }

    private func names(_ graph: [String: Any], class type: String, field: String) -> [String] {
        graph.values.compactMap { $0 as? [String: Any] }
            .filter { $0["class_type"] as? String == type }
            .compactMap { ($0["inputs"] as? [String: Any])?[field] as? String }
    }

    private var videoGraphs: [ForgeGraph] {
        let plain = ForgeRecipe(prompt: "a cat", seed: 1)
        let asset = ForgeAsset(filename: "forge_00001.mp4", subfolder: "video")
        return [
            ForgeGraph(recipe: plain),
            ForgeGraph(recipe: plain.with(frame: .kept("photo.png"))),
            ForgeGraph(recipe: plain.with(frame: .clipEnd(asset))),
        ]
    }

    @Test("The video catalog names exactly the classes the video graph can contain")
    func videoNodes() {
        var used = Set<String>()
        for graph in videoGraphs { used.formUnion(graph.nodes.map(\.classType)) }
        let catalog = Set(MediaRequirements.video.nodes.map(\.classType))
        #expect(used.isSubset(of: catalog), "unlisted: \(used.subtracting(catalog))")
        #expect(catalog == Set(ForgeClass.outputs.keys), "extra: \(catalog.symmetricDifference(Set(ForgeClass.outputs.keys)))")
    }

    @Test("The video graph's loaders ask for exactly the five files the catalog lists")
    func videoFiles() {
        let graph = videoGraphs[0].payload
        let asked: Set<String> = Set(
            names(graph, class: "UNETLoader", field: "unet_name")
                + names(graph, class: "CLIPLoader", field: "clip_name")
                + names(graph, class: "VAELoader", field: "vae_name")
                + names(graph, class: "LatentUpscaleModelLoader", field: "model_name"))
        #expect(asked == Set(MediaRequirements.video.files.map(\.name)))
    }

    @Test("Every picture engine's graph, painting or editing, stays inside its lane")
    func imageLanes() {
        var seen = Set<String>()
        for engine in ImageGenEngine.allCases {
            let spec = MediaRequirements.image(engine)
            for mode in [ImageGenMode.generate, .edit] {
                let recipe = ImageGenRecipe(
                    prompt: "a fox", engine: engine, mode: mode,
                    references: mode == .edit ? ["ref.png"] : [])
                let graph = ImageGenClient.graph(recipe)
                let used = classes(graph)
                let catalog = Set(spec.nodes.map(\.classType))
                #expect(used.isSubset(of: catalog), "\(engine) \(mode): \(used.subtracting(catalog))")
                seen.formUnion(used)
                let files = Set(
                    names(graph, class: "UNETLoader", field: "unet_name")
                        + names(graph, class: "CLIPLoader", field: "clip_name")
                        + names(graph, class: "VAELoader", field: "vae_name"))
                #expect(files == Set(spec.files.map(\.name)), "\(engine) \(mode): \(files)")
            }
        }
        #expect(seen == Set(MediaRequirements.imageNodes.map(\.classType)))
    }

    @Test("Every model file the picture code knows is in the catalog, with the same path")
    func imageCatalog() {
        for file in ImageGenModelFile.all {
            let known = MediaRequirements.file(named: file.name)
            #expect(known?.path == file.path, "\(file.path)")
        }
    }

    @Test("Roles are unique and every file has a folder ComfyUI lists")
    func shape() {
        let roles = MediaRequirements.allFiles.map(\.role)
        #expect(Set(roles).count == roles.count)
        #expect(Set(roles) == Set(MediaRole.allCases))
        let folders: Set<String> = ["diffusion_models", "text_encoders", "vae", "latent_upscale_models"]
        for file in MediaRequirements.allFiles {
            #expect(folders.contains(file.folder), "\(file.name)")
            #expect(file.bytes > 100_000_000, "\(file.name) is not a plausible size")
            #expect(file.name.hasSuffix(".safetensors"))
        }
    }

    @Test("What is published is published at the path the folder implies")
    func sources() {
        for file in MediaRequirements.publicFiles {
            #expect(file.repositoryPath == file.path, "\(file.name)")
            #expect(file.repository?.revision.count == 40)
        }
        #expect(MediaRequirements.unpublishedFiles.isEmpty)
        #expect(MediaRequirements.unpublishedNodes.isEmpty)
        #expect(MediaRequirements.video.files.allSatisfy { $0.repository == .ltx })
    }

    @Test("The video lane adds up to the 70 GB the document promises")
    func videoSize() {
        #expect(MediaRequirements.video.totalBytes == 71_114_917_404)
        #expect(MediaReading.size(MediaRequirements.videoModel.bytes) == "42 GB")
        #expect(MediaReading.size(MediaRequirements.videoEncoder.bytes) == "26.3 GB")
        #expect(MediaReading.size(MediaRequirements.videoVAE.bytes) == "1.5 GB")
        #expect(MediaReading.size(MediaRequirements.qwenVAE.bytes) == "676 MB")
    }

    @Test("A fetch command is the exact hf download line, one repository at a time, quoting what needs it")
    func commands() {
        let line = MediaCommands.fetch([MediaRequirements.videoModel], into: "/home/a b/ComfyUI/models")
        #expect(
            line
                == "hf download Lightricks/LTX-2.5 --revision 49b093a39c19169a8a81721dcc541e07e945232f diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors --local-dir '/home/a b/ComfyUI/models'"
        )
        #expect(
            MediaCommands.fetch(
                [MediaRequirements.videoModel, MediaRequirements.qwenVAE], into: "~/m") == nil,
            "two repositories are two commands, never one")
        let both = MediaCommands.fetchAll(
            [MediaRequirements.videoModel, MediaRequirements.qwenVAE, MediaRequirements.videoVAE], into: "~/m")
        #expect(both?.components(separatedBy: " && ").count == 2)
        #expect(both?.contains("diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors vae/ltx-2.5-video-vae-bf16.safetensors") == true)
        let hidden = MediaFile(
            role: .videoModel, folder: "vae", name: "x.safetensors", bytes: 1, source: .unpublished)
        #expect(MediaCommands.fetch([hidden], into: "~/m") == nil, "nothing is said to download what nobody has published")
        #expect(MediaCommands.fetchAll([hidden], into: "~/m") == nil)
        #expect(MediaCommands.update(into: "/opt/ComfyUI").contains("git checkout v0.41.2"))
    }

    @Test("Versions compare as numbers")
    func versions() {
        #expect(MediaVersion("0.9.2") < MediaVersion("0.41.0"))
        #expect(MediaVersion("v0.41.2") > MediaVersion("0.41"))
        #expect(!(MediaVersion("0.37.0") < MediaVersion("0.37")))
    }

    @Test("The install script downloads exactly the files, revisions and release the catalog names")
    func scriptMatchesCatalog() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let script = try String(contentsOf: url.appendingPathComponent("scripts/media-setup.sh"), encoding: .utf8)
        for file in MediaRequirements.allFiles {
            #expect(script.contains("\"\(file.repositoryPath ?? "")\""), "\(file.name) is not in the script")
        }
        for repository in [MediaRepository.ltx, .qwenImage, .klein] {
            #expect(script.contains("\"\(repository.id)\""), Comment(rawValue: repository.id))
            #expect(script.contains("\"\(repository.revision)\""), Comment(rawValue: repository.revision))
        }
        #expect(script.contains("COMFYUI_TAG=\"\(MediaRequirements.comfyUITag)\""))
        #expect(script.contains("COMFYUI_COMMIT=\"\(MediaRequirements.comfyUICommit)\""))
        let video = MediaRequirements.video.totalBytes
        #expect(script.contains("VIDEO_BYTES=\(video)"))
        let qwen = MediaRequirements.qwenModel.bytes + MediaRequirements.qwenTurboModel.bytes
            + MediaRequirements.qwenEncoder.bytes + MediaRequirements.qwenVAE.bytes
        #expect(script.contains("QWEN_BYTES=\(qwen)"))
        let klein = MediaRequirements.fast.totalBytes
        #expect(script.contains("KLEIN_BYTES=\(klein)"))
    }
}
