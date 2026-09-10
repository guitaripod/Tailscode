import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The one place this app talks to ComfyUI. The server's API is a queue: POST a graph, read a
/// prompt id, follow the run on its socket or poll history until it settles, then fetch the file
/// it named. Every failure comes back as a sentence a person can act on, the way `MediaFailure`
/// does for the watch board — a queue error nobody can read is not an answer.
public enum ImageGenFailure: Error, Sendable {
    case unreachable
    case refused(String)
    case invalid(String)

    public var reason: String {
        switch self {
        case .unreachable: return Localized.text("ComfyUI is not answering")
        case .refused(let detail): return detail
        case .invalid(let detail): return detail
        }
    }
}

/// One queued render, as the API speaks about it: a prompt id to follow, and the graph's own
/// node classes so a frame that names a node can be read as a stage.
public struct ImageGenRequest: Sendable, Equatable {
    public let id: String
    public let nodeClasses: [String: String]

    public init(id: String, nodeClasses: [String: String] = [:]) {
        self.id = id
        self.nodeClasses = nodeClasses
    }
}

public struct ImageGenClient: Sendable {
    public let endpoint: ImageGenEndpoint
    private let session: URLSession

    /// Who this device is to the machine's socket. ComfyUI addresses a render's frames to the
    /// client id that queued it, and keeps one socket per id — two devices sharing a name would
    /// take each other's progress away — so each device carries its own, once, forever.
    public static var clientID: String { ImageGenStore.clientID() }

    public init(endpoint: ImageGenEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }

    /// POSTs a request, tolerating a server that is waking. Booting torch and scanning the model
    /// store takes the socket-activated server the better part of a minute, and the first
    /// contact is what wakes it — so the request retries until the boot window closes rather
    /// than failing the morning's first render.
    private static func wakingPost(
        _ request: URLRequest, session: URLSession
    ) async throws -> (Data, URLResponse) {
        for attempt in 0..<9 {
            do {
                return try await session.data(for: request)
            } catch {
                guard attempt < 8 else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(10_000_000_000 * (attempt + 1)))
            }
        }
        throw ImageGenFailure.unreachable
    }

    /// GETs a URL, tolerating a server that is waking: a socket-activated ComfyUI answers
    /// nothing for the seconds its boot takes, and the first contact is what wakes it. One
    /// retry after that boot window covers the whole morning-first-render path.
    private func tolerantGet(_ url: URL) async -> (Data, URLResponse)? {
        do {
            return try await session.data(from: url)
        } catch {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            return try? await session.data(from: url)
        }
    }

    /// The queue's own answer: is the machine there, which model files it holds, what version it
    /// runs and what it is doing right now.
    public func health() async -> ImageGenHealth {
        guard let url = endpoint.url("/system_stats") else { return .unknown() }
        guard let (data, response) = await tolerantGet(url),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else {
            return ImageGenHealth(reachable: false, missingModels: [], version: nil)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let system = object?["system"] as? [String: Any]
        let version = system?["comfyui_version"] as? String
        async let missing = missingModels()
        async let running = queuedCount()
        return ImageGenHealth(
            reachable: true, missingModels: await missing, version: version,
            running: await running)
    }

    /// Which loader answers for a family of model files, and under which field. A store keeps
    /// diffusion models, text encoders and VAEs in three directories and ComfyUI publishes each
    /// one through its own node, so asking a single node about all three is asking a question it
    /// has no way to answer — and taking its silence for absence is how every model reads as
    /// missing on a machine that holds all of them.
    private static let loaders: [String: (node: String, field: String)] = [
        "diffusion_models": ("UNETLoader", "unet_name"),
        "text_encoders": ("CLIPLoader", "clip_name"),
        "vae": ("VAELoader", "vae_name"),
    ]

    private func available(from loader: (node: String, field: String)) async -> [String]? {
        guard let url = endpoint.url("/object_info/\(loader.node)") else { return nil }
        guard let (data, _) = try? await session.data(from: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let node = object[loader.node] as? [String: Any],
            let input = node["input"] as? [String: Any],
            let required = input["required"] as? [String: Any],
            let field = required[loader.field] as? [Any],
            let names = field.first as? [String]
        else { return nil }
        return names
    }

    /// The required files the store cannot offer. A loader this server does not publish is
    /// reported as its whole family missing rather than quietly passing, because a graph that
    /// names a node ComfyUI has never heard of fails at queue time with an error nobody can read.
    private func missingModels() async -> [String] {
        var missing: [String] = []
        for (directory, loader) in Self.loaders {
            let wanted = ImageGenModelFile.all.filter { $0.directory == directory }
            guard !wanted.isEmpty else { continue }
            guard let names = await available(from: loader) else {
                missing.append(contentsOf: wanted.map(\.path))
                continue
            }
            let offered = Set(names.map { ($0 as NSString).lastPathComponent })
            missing.append(contentsOf: wanted.filter { !offered.contains($0.name) }.map(\.path))
        }
        return missing.sorted()
    }

    /// The graph for one ask, built once so the runner can queue it and read its nodes back.
    public static func graph(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        seed: UInt64, referenceName: String?
    ) -> [String: Any] {
        switch engine {
        case .quality:
            return qwenGraph(
                prompt: prompt, mode: mode, aspect: aspect, seed: seed, referencePath: referenceName)
        case .fast:
            if mode == .edit, let referenceName {
                return kleinEditGraph(prompt: prompt, seed: seed, referencePath: referenceName)
            }
            return kleinGraph(prompt: prompt, aspect: aspect, seed: seed)
        }
    }

    /// Queues one render. The graph is built for the engine and mode; the seed is the caller's
    /// so a retry can be exact and a reroll can be fresh.
    public func queue(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        seed: UInt64, referencePath: String?
    ) async throws -> ImageGenRequest {
        try await queue(
            Self.graph(
                prompt: prompt, engine: engine, mode: mode, aspect: aspect, seed: seed,
                referenceName: referencePath))
    }

    public func queue(_ graph: [String: Any]) async throws -> ImageGenRequest {
        let body: [String: Any] = ["prompt": graph, "client_id": Self.clientID]
        guard let url = endpoint.url("/prompt") else {
            throw ImageGenFailure.invalid("bad endpoint address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse) = try await Self.wakingPost(
            request, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errors = detail?["node_errors"] as? [String: Any]
            let first = errors?.values.first as? [String: Any]
            let list = first?["errors"] as? [[String: Any]]
            let top = detail?["error"] as? [String: Any]
            let message = (list?.first?["message"] as? String)
                ?? (top?["message"] as? String)
                ?? "ComfyUI refused the request"
            throw ImageGenFailure.refused(message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["prompt_id"] as? String
        else { throw ImageGenFailure.invalid("ComfyUI answered without a prompt id") }
        let classes = graph.reduce(into: [String: String]()) { seen, entry in
            seen[entry.key] = (entry.value as? [String: Any])?["class_type"] as? String
        }
        return ImageGenRequest(id: id, nodeClasses: classes)
    }

    /// Puts a picture in the machine's own input directory and hands back the name the graph
    /// must call it by. The reference a person attaches is a file on the device they attached it
    /// from — a phone's photo library has no path the renderer could ever open — so the bytes
    /// travel and the name comes back.
    public func upload(fileAt path: String) async throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ImageGenFailure.invalid(Localized.text("The reference picture could not be read"))
        }
        return try await upload(data, named: (path as NSString).lastPathComponent)
    }

    public func upload(_ data: Data, named name: String) async throws -> String {
        guard let url = endpoint.url("/upload/image") else {
            throw ImageGenFailure.invalid("bad endpoint address")
        }
        let boundary = "tailscode-" + UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart(data, named: name, boundary: boundary)
        let (answer, response) = try await Self.wakingPost(request, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
            let stored = object["name"] as? String
        else {
            throw ImageGenFailure.refused(
                Localized.text("ComfyUI would not take the reference picture"))
        }
        let subfolder = object["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? stored : subfolder + "/" + stored
    }

    private static func multipart(_ data: Data, named name: String, boundary: String) -> Data {
        var body = Data()
        func write(_ text: String) { body.append(Data(text.utf8)) }
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\n")
        write("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        write("\r\n--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n")
        write("true\r\n")
        write("--\(boundary)--\r\n")
        return body
    }

    /// Polls a queued run once. Returns nil while it still runs; `.success` when a picture is
    /// ready to fetch; a failure when the run says it failed.
    public func poll(_ request: ImageGenRequest) async -> Result<Void, ImageGenFailure>? {
        guard let url = endpoint.url("/history/" + request.id) else {
            return .failure(.invalid("bad endpoint address"))
        }
        guard let (data, _) = await tolerantGet(url),
            let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let run = history[request.id] as? [String: Any]
        else { return nil }
        guard let status = run["status"] as? [String: Any],
            let state = status["status_str"] as? String
        else { return nil }
        if state == "error" {
            let messages = status["messages"] as? [[Any]]
            let error = messages?.first { ($0.first as? String) == "execution_error" }
            let body = error?.last as? [String: Any]
            let node = body?["node_type"] as? String
            let exception = body?["exception_message"] as? String
            let words = [node, exception].compactMap { $0 }.joined(separator: ": ")
            return .failure(.refused(words.isEmpty ? "the run failed" : words))
        }
        guard state == "success" else { return nil }
        let outputs = run["outputs"] as? [String: [String: Any]]
        let images = outputs?.values.first?["images"] as? [[String: Any]]
        guard images?.first?["filename"] != nil else {
            return .failure(.invalid("the run finished without a picture"))
        }
        return .success(())
    }

    /// Reads the finished picture's bytes from the server's view endpoint, and the name the
    /// machine gave the file — which is how the render is found again in the machine's gallery.
    public func fetch(request: ImageGenRequest) async throws -> (Data, String) {
        guard let url = endpoint.url("/history/" + request.id) else {
            throw ImageGenFailure.invalid("bad endpoint address")
        }
        guard let (data, _) = await tolerantGet(url),
            let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let run = history[request.id] as? [String: Any],
            let outputs = run["outputs"] as? [String: [String: Any]]
        else { throw ImageGenFailure.invalid("the run's history is gone") }
        for output in outputs.values {
            guard let images = output["images"] as? [[String: Any]] else { continue }
            for image in images {
                guard let filename = image["filename"] as? String else { continue }
                let subfolder = image["subfolder"] as? String ?? ""
                let item = ImageGenLibraryItem(filename: filename, subfolder: subfolder)
                guard let view = viewURL(item) else { continue }
                let (bytes, _) = try await session.data(from: view)
                return (bytes, item.id)
            }
        }
        throw ImageGenFailure.invalid("the run finished without a picture")
    }

    /// Whether a render this client queued is still on the machine's queue, and where. Read
    /// before stopping one, because the two ways of stopping are not the same call.
    public enum QueuePlace: Sendable, Equatable {
        case pending
        case running
        case gone
    }

    public func place(of request: ImageGenRequest) async -> QueuePlace {
        guard let url = endpoint.url("/queue"),
            let (data, _) = try? await session.data(from: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .gone }
        return Self.place(of: request.id, inQueue: object)
    }

    public static func place(of id: String, inQueue object: [String: Any]) -> QueuePlace {
        func holds(_ key: String) -> Bool {
            let entries = object[key] as? [[Any]] ?? []
            return entries.contains { entry in entry.count > 1 && (entry[1] as? String) == id }
        }
        if holds("queue_running") { return .running }
        if holds("queue_pending") { return .pending }
        return .gone
    }

    /// Takes a render off the machine, the precise way: a render still waiting is deleted from the
    /// queue and never costs a second of the card; one already running is interrupted, which is
    /// the machine's own word for it. A render the queue no longer holds is left alone — it has
    /// finished or failed and history will say which.
    public func stop(_ request: ImageGenRequest) async {
        switch await place(of: request) {
        case .pending:
            guard let url = endpoint.url("/queue") else { return }
            var post = URLRequest(url: url)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.httpBody = try? JSONSerialization.data(withJSONObject: ["delete": [request.id]])
            _ = try? await session.data(for: post)
        case .running:
            guard let url = endpoint.url("/interrupt") else { return }
            var post = URLRequest(url: url)
            post.httpMethod = "POST"
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            post.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())
            _ = try? await session.data(for: post)
        case .gone:
            break
        }
    }

    /// How many renders the machine is running right now — anybody's, not only this device's.
    public func queuedCount() async -> Int {
        guard let url = endpoint.url("/queue") else { return 0 }
        guard let (data, _) = try? await session.data(from: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let running = object["queue_running"] as? [[Any]]
        else { return 0 }
        return running.count
    }

    /// The route a kept picture is read from. `preview` asks the machine for a re-encoded copy at
    /// a fraction of the bytes, which is what a tile wants and a save must never take.
    public func viewURL(_ item: ImageGenLibraryItem, preview: ImageGenFileKind? = nil) -> URL? {
        var query = ["filename": item.filename, "type": "output"]
        if !item.subfolder.isEmpty { query["subfolder"] = item.subfolder }
        if let preview { query["preview"] = "\(preview.rawValue);70" }
        return endpoint.url("/view", query: query)
    }

    /// Everything the machine has made, newest first. The route is ComfyUI's own listing of its
    /// output directory; a server without it answers 404, which is *this machine cannot say* and
    /// must read as that rather than as an empty shelf.
    public func listOutputs() async -> Result<[ImageGenLibraryItem], ImageGenLibraryFailure> {
        guard let url = endpoint.url("/internal/files/output") else { return .failure(.unreachable) }
        guard let (data, response) = await tolerantGet(url),
            let http = response as? HTTPURLResponse
        else { return .failure(.unreachable) }
        if http.statusCode == 404 { return .failure(.unsupported) }
        guard http.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return .failure(.refused(Localized.text("The machine would not list its pictures")))
        }
        return .success(ImageGenLibraryReading.items(fromListing: object))
    }

    /// The head of one kept file: its date and size off the headers, its dimensions and the graph
    /// that made it off the first bytes. One ranged request, whatever the picture weighs.
    public func describe(_ item: ImageGenLibraryItem) async -> ImageGenLibraryFacts? {
        guard let url = viewURL(item) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(PNGHead.probeBytes - 1)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode < 400
        else { return nil }
        var facts = PNGHead.facts(data)
        facts.modifiedAt = ImageGenLibraryReading.date(
            fromHTTP: http.value(forHTTPHeaderField: "Last-Modified"))
        facts.bytes = ImageGenLibraryReading.total(
            fromContentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: http.statusCode == 206
                ? nil : http.value(forHTTPHeaderField: "Content-Length"))
        return facts
    }

    /// A small copy of a kept picture for a tile, re-encoded by the machine.
    public func thumbnail(_ item: ImageGenLibraryItem, format: ImageGenFileKind) async -> Data? {
        guard let url = viewURL(item, preview: format) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
            let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }

    /// The file as the machine wrote it, for the stage, a save or a share.
    public func original(_ item: ImageGenLibraryItem) async throws -> Data {
        guard let url = viewURL(item) else { throw ImageGenFailure.invalid("bad endpoint address") }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw ImageGenFailure.refused(Localized.text("The machine no longer has this picture"))
        }
        return data
    }

    /// Qwen-Image-Edit-2511 as the store runs it: fp8mixed transformer, the VL text encoder,
    /// one shared VAE. With no reference latent the same graph paints from words alone.
    static func qwenGraph(
        prompt: String, mode: ImageGenMode, aspect: ImageGenAspect, seed: UInt64,
        referencePath: String?
    ) -> [String: Any] {
        let size = aspect.pixels
        let negative = ""
        var graph: [String: Any] = [
            "12": ["class_type": "UNETLoader", "inputs": [
                "unet_name": "qwen_image_edit_2511_fp8mixed.safetensors",
                "weight_dtype": "default",
            ]],
            "61": ["class_type": "CLIPLoader", "inputs": [
                "clip_name": "qwen_2.5_vl_7b_fp8_scaled.safetensors",
                "type": "qwen_image", "device": "default",
            ]],
            "10": ["class_type": "VAELoader", "inputs": [
                "vae_name": "qwen_image_vae.safetensors",
            ]],
            "90": ["class_type": "ModelSamplingAuraFlow", "inputs": [
                "model": ["12", 0], "shift": 3.1,
            ]],
            "64": ["class_type": "CFGNorm", "inputs": [
                "model": ["90", 0], "strength": 1.0, "set_cfg_norm": false,
            ]],
            "66": ["class_type": "EmptySD3LatentImage", "inputs": [
                "width": size.width, "height": size.height, "batch_size": 1,
            ]],
            "65": ["class_type": "KSampler", "inputs": [
                "model": ["64", 0], "positive": ["70", 0], "negative": ["71", 0],
                "latent_image": ["66", 0], "seed": Int(clamping: seed),
                "steps": 30, "cfg": 1.0, "sampler_name": "euler",
                "scheduler": "simple", "denoise": 1.0,
            ]],
            "8": ["class_type": "VAEDecode", "inputs": [
                "samples": ["65", 0], "vae": ["10", 0],
            ]],
            "9": ["class_type": "SaveImage", "inputs": [
                "images": ["8", 0], "filename_prefix": "tailscode",
            ]],
        ]
        if mode == .edit, let referencePath {
            graph["81"] = ["class_type": "LoadImage", "inputs": ["image": referencePath]]
            graph["88"] = ["class_type": "FluxKontextImageScale", "inputs": [
                "image": ["81", 0],
            ]]
            graph["68"] = ["class_type": "TextEncodeQwenImageEditPlus", "inputs": [
                "clip": ["61", 0], "vae": ["10", 0], "prompt": prompt, "image1": ["88", 0],
            ]]
            graph["69"] = ["class_type": "TextEncodeQwenImageEditPlus", "inputs": [
                "clip": ["61", 0], "vae": ["10", 0], "prompt": negative, "image1": ["88", 0],
            ]]
            graph["75"] = ["class_type": "VAEEncode", "inputs": [
                "pixels": ["88", 0], "vae": ["10", 0],
            ]]
            graph["65"] = ["class_type": "KSampler", "inputs": [
                "model": ["64", 0], "positive": ["70", 0], "negative": ["71", 0],
                "latent_image": ["75", 0], "seed": Int(clamping: seed),
                "steps": 30, "cfg": 1.0, "sampler_name": "euler",
                "scheduler": "simple", "denoise": 1.0,
            ]]
        } else {
            graph["68"] = ["class_type": "CLIPTextEncode", "inputs": [
                "clip": ["61", 0], "text": prompt,
            ]]
            graph["69"] = ["class_type": "CLIPTextEncode", "inputs": [
                "clip": ["61", 0], "text": negative,
            ]]
        }
        graph["70"] = ["class_type": "FluxKontextMultiReferenceLatentMethod", "inputs": [
            "conditioning": ["68", 0], "reference_latents_method": "index_timestep_zero",
        ]]
        graph["71"] = ["class_type": "FluxKontextMultiReferenceLatentMethod", "inputs": [
            "conditioning": ["69", 0], "reference_latents_method": "index_timestep_zero",
        ]]
        return graph
    }

    private static func kleinLoaders() -> [String: Any] {
        [
        "70": ["class_type": "UNETLoader", "inputs": [
            "unet_name": "flux-2-klein-4b.safetensors", "weight_dtype": "default",
        ]],
        "71": ["class_type": "CLIPLoader", "inputs": [
            "clip_name": "qwen_3_4b.safetensors", "type": "flux2", "device": "default",
        ]],
        "72": ["class_type": "VAELoader", "inputs": ["vae_name": "flux2-vae.safetensors"]],
        "61": ["class_type": "KSamplerSelect", "inputs": ["sampler_name": "euler"]],
        "65": ["class_type": "VAEDecode", "inputs": [
            "samples": ["64", 0], "vae": ["72", 0],
        ]],
        "9": ["class_type": "SaveImage", "inputs": [
            "images": ["65", 0], "filename_prefix": "tailscode",
        ]],
        ]
    }

    /// FLUX.2 Klein 4B distilled: four steps, the graph the store verified, driven from an
    /// empty latent so the fast lane paints from words alone.
    static func kleinGraph(prompt: String, aspect: ImageGenAspect, seed: UInt64)
        -> [String: Any]
    {
        let size = aspect.pixels
        var graph = kleinLoaders()
        graph["66"] = ["class_type": "EmptyFlux2LatentImage", "inputs": [
            "width": size.width, "height": size.height, "batch_size": 1,
        ]]
        graph["62"] = ["class_type": "Flux2Scheduler", "inputs": [
            "width": size.width, "height": size.height, "steps": 4,
        ]]
        graph["74"] = ["class_type": "CLIPTextEncode", "inputs": [
            "clip": ["71", 0], "text": prompt,
        ]]
        graph["82"] = ["class_type": "ConditioningZeroOut", "inputs": [
            "conditioning": ["74", 0],
        ]]
        graph["123"] = ["class_type": "ReferenceLatent", "inputs": [
            "conditioning": ["74", 0],
        ]]
        graph["121"] = ["class_type": "ReferenceLatent", "inputs": [
            "conditioning": ["82", 0],
        ]]
        graph["63"] = ["class_type": "CFGGuider", "inputs": [
            "model": ["70", 0], "positive": ["123", 0], "negative": ["121", 0],
            "cfg": 1.0,
        ]]
        graph["73"] = ["class_type": "RandomNoise", "inputs": [
            "noise_seed": Int(clamping: seed),
        ]]
        graph["64"] = ["class_type": "SamplerCustomAdvanced", "inputs": [
            "noise": ["73", 0], "guider": ["63", 0], "sampler": ["61", 0],
            "sigmas": ["62", 0], "latent_image": ["66", 0],
        ]]
        return graph
    }

    /// Klein editing a picture, exactly as the store verified it: the reference is scaled to one
    /// megapixel on a 64-pixel grid, its size becomes the canvas, and its encoded latent rides
    /// both conditionings as the reference. The fast lane used to ignore the reference and paint
    /// from words alone while the button said Edit.
    static func kleinEditGraph(prompt: String, seed: UInt64, referencePath: String)
        -> [String: Any]
    {
        var graph = kleinLoaders()
        graph["81"] = ["class_type": "LoadImage", "inputs": ["image": referencePath]]
        graph["80"] = ["class_type": "ImageScaleToTotalPixels", "inputs": [
            "image": ["81", 0], "upscale_method": "nearest-exact", "megapixels": 1.0,
            "resolution_steps": 64,
        ]]
        graph["99"] = ["class_type": "GetImageSize", "inputs": ["image": ["80", 0]]]
        graph["66"] = ["class_type": "EmptyFlux2LatentImage", "inputs": [
            "width": ["99", 0], "height": ["99", 1], "batch_size": 1,
        ]]
        graph["62"] = ["class_type": "Flux2Scheduler", "inputs": [
            "width": ["99", 0], "height": ["99", 1], "steps": 4,
        ]]
        graph["74"] = ["class_type": "CLIPTextEncode", "inputs": [
            "clip": ["71", 0], "text": prompt,
        ]]
        graph["82"] = ["class_type": "ConditioningZeroOut", "inputs": [
            "conditioning": ["74", 0],
        ]]
        graph["122"] = ["class_type": "VAEEncode", "inputs": [
            "pixels": ["80", 0], "vae": ["72", 0],
        ]]
        graph["123"] = ["class_type": "ReferenceLatent", "inputs": [
            "conditioning": ["74", 0], "latent": ["122", 0],
        ]]
        graph["121"] = ["class_type": "ReferenceLatent", "inputs": [
            "conditioning": ["82", 0], "latent": ["122", 0],
        ]]
        graph["63"] = ["class_type": "CFGGuider", "inputs": [
            "model": ["70", 0], "positive": ["123", 0], "negative": ["121", 0],
            "cfg": 1.0,
        ]]
        graph["73"] = ["class_type": "RandomNoise", "inputs": [
            "noise_seed": Int(clamping: seed),
        ]]
        graph["64"] = ["class_type": "SamplerCustomAdvanced", "inputs": [
            "noise": ["73", 0], "guider": ["63", 0], "sampler": ["61", 0],
            "sigmas": ["62", 0], "latent_image": ["66", 0],
        ]]
        return graph
    }
}
