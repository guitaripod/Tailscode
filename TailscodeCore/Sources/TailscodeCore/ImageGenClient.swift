import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The one place this app talks to ComfyUI. The server's API is a queue: POST a graph, read a
/// prompt id, poll history until the run settles, then fetch the file it named. Every failure
/// comes back as a sentence a person can act on, the way `MediaFailure` does for the watch
/// board — a queue error nobody can read is not an answer.
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

/// One queued render, as the API speaks about it: a prompt id to poll and nothing else.
public struct ImageGenRequest: Sendable, Equatable {
    public let id: String
    /// How many images one run names — one, until a batch is ever wanted.
    public var count: Int = 1
}

/// Progress as the store reports it, in the terms the slot's UI shows: steps done of the total,
/// and the wall-clock seconds the run has taken.
public struct ImageGenProgress: Sendable, Equatable {
    public let step: Int
    public let of: Int
    public let seconds: Double

    public var fraction: Double {
        of > 0 ? Double(step) / Double(of) : 0
    }
}

public struct ImageGenClient: Sendable {
    public let endpoint: ImageGenEndpoint
    private let session: URLSession

    public init(endpoint: ImageGenEndpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }

    /// POSTs a graph, tolerating a server that is waking. Booting torch and scanning the model
    /// store takes the socket-activated server the better part of a minute, and the first
    /// contact is what wakes it — so the queue request retries until the boot window closes
    /// rather than failing the morning's first render.
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

    /// The queue's own answer: is the machine there, and is the API the shape we speak.
    public func health() async -> ImageGenHealth {
        guard let url = URL(string: endpoint.address + "/system_stats") else {
            return .unknown()
        }
        guard let (data, response) = await tolerantGet(url),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else {
            return ImageGenHealth(reachable: false, missingModels: [], version: nil)
        }
        do {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let system = object?["system"] as? [String: Any]
            let version = system?["comfyui_version"] as? String
            let missing = await missingModels()
            return ImageGenHealth(reachable: true, missingModels: missing, version: version)
        }
    }

    private static let required = [
        "diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors",
        "diffusion_models/flux-2-klein-4b.safetensors",
        "text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors",
        "text_encoders/qwen_3_4b.safetensors",
        "vae/qwen_image_vae.safetensors",
        "vae/flux2-vae.safetensors",
    ]

    private func missingModels() async -> [String] {
        guard let url = URL(string: endpoint.address + "/object_info/UNETLoader") else {
            return Self.required
        }
        guard let (data, _) = try? await session.data(from: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let loader = object["UNETLoader"] as? [String: Any],
            let input = loader["input"] as? [String: Any],
            let required = input["required"] as? [String: Any],
            let unet = required["unet_name"] as? [Any],
            let available = unet.first as? [String]
        else { return Self.required }
        return Self.required.filter { name in
            !available.contains(where: { $0.hasSuffix(name) })
        }
    }

    /// Queues one render. The graph is built for the engine and mode; the seed is the caller's
    /// so a retry can be exact and a reroll can be fresh.
    public func queue(
        prompt: String, engine: ImageGenEngine, mode: ImageGenMode, aspect: ImageGenAspect,
        seed: UInt64, referencePath: String?
    ) async throws -> ImageGenRequest {
        var graph: [String: Any]
        switch engine {
        case .quality:
            graph = Self.qwenGraph(
                prompt: prompt, mode: mode, aspect: aspect, seed: seed,
                referencePath: referencePath)
        case .fast:
            graph = try Self.kleinGraph(prompt: prompt, aspect: aspect, seed: seed)
        }
        let body: [String: Any] = ["prompt": graph, "client_id": "tailscode"]
        guard let url = URL(string: endpoint.address + "/prompt") else {
            throw ImageGenFailure.invalid("bad endpoint address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A socket-activated server is woken by this very request and answers nothing for the
        // seconds its boot takes. Retrying inside the wake window is what makes the first
        // render of the morning work instead of failing.
        let (data, response): (Data, URLResponse) = try await Self.wakingPost(
            request, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errors = detail?["node_errors"] as? [String: Any]
            let first = errors?.values.first as? [String: Any]
            let list = first?["errors"] as? [[String: Any]]
            let message = (list?.first?["message"] as? String) ?? "ComfyUI refused the request"
            throw ImageGenFailure.refused(message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["prompt_id"] as? String
        else { throw ImageGenFailure.invalid("ComfyUI answered without a prompt id") }
        return ImageGenRequest(id: id)
    }

    /// Polls a queued run once. Returns nil while it still runs; `.success` when a picture is
    /// ready to fetch; a failure when the run says it failed.
    public func poll(_ request: ImageGenRequest) async -> Result<Void, ImageGenFailure>? {
        guard let url = URL(string: endpoint.address + "/history/" + request.id) else {
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

    /// Reads the finished picture's bytes from the server's view endpoint, and the seconds it
    /// took — read off the run's own timing when the history carries it.
    public func fetch(request: ImageGenRequest) async throws -> (Data, String) {
        guard let url = URL(string: endpoint.address + "/history/" + request.id) else {
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
                var parts = [endpoint.address, "/view?filename=",
                    Self.escaped(filename), "&type=output"]
                if !subfolder.isEmpty {
                    parts.append("&subfolder=" + Self.escaped(subfolder))
                }
                guard let view = URL(string: parts.joined()) else { continue }
                let (bytes, _) = try await session.data(from: view)
                return (bytes, filename)
            }
        }
        throw ImageGenFailure.invalid("the run finished without a picture")
    }

    /// Progress off the queue's own websocket-free path: `/prompt` answers what is still queued,
    /// and the sampler's step count rides the history once it exists. The client shows time and
    /// the queue's length, which is what the API can honestly say.
    public func queuedCount() async -> Int {
        guard let url = URL(string: endpoint.address + "/queue") else { return 0 }
        guard let (data, _) = try? await session.data(from: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let running = object["queue_running"] as? [[Any]]
        else { return 0 }
        return running.count
    }

    private static func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }

    // MARK: - Graphs

    /// Qwen-Image-Edit-2511 as the store runs it: fp8mixed transformer, the VL text encoder,
    /// one shared VAE. With no reference latent the same graph paints from words alone.
    static func qwenGraph(
        prompt: String, mode: ImageGenMode, aspect: ImageGenAspect, seed: UInt64,
        referencePath: String?
    ) -> [String: Any] {
        let size = aspect.pixels
        let negative = mode == .edit ? "" : ""
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

    /// FLUX.2 Klein 4B distilled: four steps, the graph the store verified, driven from an
    /// empty latent so the fast lane paints from words alone.
    static func kleinGraph(prompt: String, aspect: ImageGenAspect, seed: UInt64)
        -> [String: Any]
    {
        let size = aspect.pixels
        return [
            "66": ["class_type": "EmptyFlux2LatentImage", "inputs": [
                "width": size.width, "height": size.height, "batch_size": 1,
            ]],
            "62": ["class_type": "Flux2Scheduler", "inputs": [
                "width": size.width, "height": size.height, "steps": 4,
            ]],
            "70": ["class_type": "UNETLoader", "inputs": [
                "unet_name": "flux-2-klein-4b.safetensors", "weight_dtype": "default",
            ]],
            "71": ["class_type": "CLIPLoader", "inputs": [
                "clip_name": "qwen_3_4b.safetensors", "type": "flux2", "device": "default",
            ]],
            "72": ["class_type": "VAELoader", "inputs": ["vae_name": "flux2-vae.safetensors"]],
            "74": ["class_type": "CLIPTextEncode", "inputs": [
                "clip": ["71", 0], "text": prompt,
            ]],
            "82": ["class_type": "ConditioningZeroOut", "inputs": [
                "conditioning": ["74", 0],
            ]],
            "123": ["class_type": "ReferenceLatent", "inputs": [
                "conditioning": ["74", 0],
            ]],
            "121": ["class_type": "ReferenceLatent", "inputs": [
                "conditioning": ["82", 0],
            ]],
            "63": ["class_type": "CFGGuider", "inputs": [
                "model": ["70", 0], "positive": ["123", 0], "negative": ["121", 0],
                "cfg": 1.0,
            ]],
            "73": ["class_type": "RandomNoise", "inputs": [
                "noise_seed": Int(clamping: seed),
            ]],
            "61": ["class_type": "KSamplerSelect", "inputs": ["sampler_name": "euler"]],
            "64": ["class_type": "SamplerCustomAdvanced", "inputs": [
                "noise": ["73", 0], "guider": ["63", 0], "sampler": ["61", 0],
                "sigmas": ["62", 0], "latent_image": ["66", 0],
            ]],
            "65": ["class_type": "VAEDecode", "inputs": [
                "samples": ["64", 0], "vae": ["72", 0],
            ]],
            "9": ["class_type": "SaveImage", "inputs": [
                "images": ["65", 0], "filename_prefix": "tailscode",
            ]],
        ]
    }
}
