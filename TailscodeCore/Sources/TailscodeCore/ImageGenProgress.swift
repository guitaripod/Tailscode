import Foundation

/// What the machine is doing to a render right now, read off its own socket rather than guessed.
/// ComfyUI announces each node as it starts and the sampler's step as it goes; a client that only
/// polled history saw done or nothing. The words are Core's so every desk narrates the same wait.
public struct ImageGenProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Accepted and waiting its turn behind this many other renders.
        case queued(ahead: Int)
        case sendingReference
        case loading
        case reading
        case encoding
        case painting
        case decoding
        case saving
    }

    public var stage: Stage
    public var step: Int?
    public var steps: Int?
    /// How far through the whole graph, counted in nodes — the honest bar, because the sampler's
    /// step counter is one node's business.
    public var fraction: Double?

    public init(stage: Stage, step: Int? = nil, steps: Int? = nil, fraction: Double? = nil) {
        self.stage = stage
        self.step = step
        self.steps = steps
        self.fraction = fraction
    }

    /// Which stage a graph node belongs to, from its class. A class this table has never heard of
    /// leaves the stage where it was rather than inventing one.
    public static func stage(forNodeClass type: String) -> Stage? {
        switch type {
        case "UNETLoader", "CLIPLoader", "VAELoader", "CheckpointLoaderSimple",
            "ModelSamplingAuraFlow", "CFGNorm", "UnetLoaderGGUF", "QwenImage21Cache":
            return .loading
        case "LoadImage", "FluxKontextImageScale", "ImageScaleToTotalPixels", "GetImageSize",
            "VAEEncode", "ReferenceMultiLatent":
            return .reading
        case "CLIPTextEncode", "TextEncodeQwenImageEditPlus", "TextEncodeQwenImage21",
            "ConditioningZeroOut", "ReferenceLatent", "FluxKontextMultiReferenceLatentMethod",
            "EmptySD3LatentImage", "EmptyLatentImage", "EmptyFlux2LatentImage", "Flux2Scheduler",
            "CFGGuider", "RandomNoise", "KSamplerSelect":
            return .encoding
        case "KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced", "SamplerCustom":
            return .painting
        case "VAEDecode": return .decoding
        case "SaveImage", "PreviewImage": return .saving
        default: return nil
        }
    }

    public var line: String {
        switch stage {
        case .queued(let ahead):
            if ahead <= 0 { return Localized.text("Waiting for the machine") }
            return ahead == 1
                ? Localized.text("Behind 1 other render")
                : Localized.text("Behind %@ other renders", "\(ahead)")
        case .sendingReference: return Localized.text("Sending the reference")
        case .loading: return Localized.text("Loading the model")
        case .reading: return Localized.text("Reading the reference")
        case .encoding: return Localized.text("Reading the words")
        case .painting:
            if let step, let steps, steps > 0 {
                return Localized.text("Painting · step %@ of %@", "\(min(step, steps))", "\(steps)")
            }
            return Localized.text("Painting")
        case .decoding: return Localized.text("Decoding the picture")
        case .saving: return Localized.text("Saving")
        }
    }

    /// A bar is drawn only once there is a count to draw it from; before that the wait is words and
    /// a clock, never a bar sitting at zero.
    public var bar: Double? {
        if case .painting = stage, let step, let steps, steps > 0 {
            return min(1, max(0, Double(step) / Double(steps)))
        }
        return nil
    }
}

extension String {
    /// Cut for a strip that must stay one line, on a word boundary where there is one.
    public func ellipsized(to limit: Int) -> String {
        guard count > limit else { return self }
        let cut = prefix(limit)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return cut + "…"
    }
}
