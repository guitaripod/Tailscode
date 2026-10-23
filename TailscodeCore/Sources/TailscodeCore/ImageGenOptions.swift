import Foundation

/// The editors the store runs, named for what they are good at rather than by version.
public enum ImageGenEngine: String, Codable, Sendable, CaseIterable {
    case quality
    case turbo
    case fast

    public var label: String {
        switch self {
        case .quality: return Localized.text("Quality")
        case .turbo: return Localized.text("Turbo")
        case .fast: return Localized.text("Fast")
        }
    }

    /// What the identity strip calls a finished picture.
    public var short: String {
        switch self {
        case .quality: return Localized.text("Qwen")
        case .turbo: return Localized.text("Qwen Turbo")
        case .fast: return Localized.text("Klein")
        }
    }

    /// What each engine is for, said once so a chip's menu and a machine sheet agree.
    public var detail: String {
        switch self {
        case .quality: return Localized.text("Qwen Image 2.1 · 25 steps · edits and paints")
        case .turbo: return Localized.text("Qwen Image 2.1 Turbo · 8 steps · edits and paints")
        case .fast: return Localized.text("FLUX 3 Klein · 16 steps · seconds, not a minute")
        }
    }

    /// The files this engine cannot run without. A machine is checked file by file, and an engine
    /// whose files are all there is offered even when the other's are not.
    public var files: [ImageGenModelFile] {
        switch self {
        case .quality: return [.qwenDiffusion, .qwenText, .qwenVAE]
        case .turbo: return [.turboDiffusion, .qwenText, .qwenVAE]
        case .fast: return [.kleinDiffusion, .kleinText, .kleinVAE]
        }
    }
}

/// One model file the store must hold, and what it is in words a person recognises. The paths
/// are ComfyUI's own — a directory and a file name — because that is how the machine names them
/// when it reports what it has.
public struct ImageGenModelFile: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let path: String
    public let role: String
    public let engine: ImageGenEngine

    public var id: String { path }

    public var name: String { (path as NSString).lastPathComponent }

    public var directory: String { (path as NSString).deletingLastPathComponent }

    public static let qwenDiffusion = ImageGenModelFile(
        path: "diffusion_models/qwen_image_2.1_int8_convrot.safetensors",
        role: Localized.text("Qwen diffusion model"), engine: .quality)

    public static let turboDiffusion = ImageGenModelFile(
        path: "diffusion_models/qwen_image_2.1_turbo_bf16.safetensors",
        role: Localized.text("Qwen Turbo diffusion model"), engine: .turbo)

    public static let qwenText = ImageGenModelFile(
        path: "text_encoders/qwen3vl_8b_int8_convrot.safetensors",
        role: Localized.text("Qwen text encoder"), engine: .quality)

    public static let qwenVAE = ImageGenModelFile(
        path: "vae/qwen_image_2.1_vae_bf16.safetensors", role: Localized.text("Qwen VAE"),
        engine: .quality)

    public static let kleinDiffusion = ImageGenModelFile(
        path: "diffusion_models/flux3_image_klein_sd_bf16.safetensors",
        role: Localized.text("Klein diffusion model"), engine: .fast)

    public static let kleinText = ImageGenModelFile(
        path: "text_encoders/qwen3vl_4b_bf16.safetensors", role: Localized.text("Klein text encoder"),
        engine: .fast)

    public static let kleinVAE = ImageGenModelFile(
        path: "vae/flux2-vae.safetensors", role: Localized.text("Klein VAE"), engine: .fast)

    public static let all: [ImageGenModelFile] = [
        qwenDiffusion, qwenText, qwenVAE, kleinDiffusion, kleinText, kleinVAE, turboDiffusion,
    ]

    public static func named(_ path: String) -> ImageGenModelFile? {
        all.first { $0.path == path || $0.name == (path as NSString).lastPathComponent }
    }
}

/// The shape of the frame, as a ratio rather than a pair of pixel counts: how big it comes out
/// is ``ImageGenSize``'s business, and holding the two apart is what lets the same six shapes be
/// asked for at 1 MP while words are being tried and at native 2K once they are right.
public enum ImageGenAspect: String, Codable, Sendable, CaseIterable {
    case square
    case landscape
    case portrait
    case screen
    case tall
    case wide

    public var ratio: (width: Int, height: Int) {
        switch self {
        case .square: return (1, 1)
        case .landscape: return (3, 2)
        case .portrait: return (2, 3)
        case .screen: return (16, 9)
        case .tall: return (9, 16)
        case .wide: return (21, 9)
        }
    }

    public var ratioLabel: String { "\(ratio.width):\(ratio.height)" }

    /// The frame at the size the model was trained for, which is what a caller with no opinion
    /// about size should get.
    public var pixels: (width: Int, height: Int) { pixels(.standard) }

    public var label: String { ratioLabel }

    public var short: String {
        switch self {
        case .square: return Localized.text("Square")
        case .landscape: return Localized.text("Landscape")
        case .portrait: return Localized.text("Portrait")
        case .screen: return Localized.text("Screen")
        case .tall: return Localized.text("Tall")
        case .wide: return Localized.text("Wide")
        }
    }

    /// One glyph per shape, so a row of them reads as shapes rather than as six words.
    public var glyph: String {
        switch self {
        case .square: return "▢"
        case .landscape: return "▭"
        case .portrait: return "▯"
        case .screen: return "▬"
        case .tall: return "▮"
        case .wide: return "▁"
        }
    }
}

/// The two decisions a picture is made from, worn as chips wherever an image is asked for — a
/// pane's own strip, the composer's lane, a phone's row.
///
/// A chip is a value that walks: pressing one changes what the next render is, immediately and
/// with nothing to confirm. Anything that opens something is not a chip and never was — whether
/// the render starts from a picture is decided by whether there is a picture attached, which is
/// the attach control's business, not a setting's.
public enum ImageGenField: String, Sendable, Equatable, CaseIterable {
    case engine
    case aspect
    case size
    case detail

    public var label: String {
        switch self {
        case .engine: return Localized.text("Engine")
        case .aspect: return Localized.text("Aspect")
        case .size: return Localized.text("Size")
        case .detail: return Localized.text("Detail")
        }
    }

    /// One symbol per decision, so a chip is read down its left edge rather than word by word.
    public var symbol: String {
        switch self {
        case .engine: return "cpu"
        case .aspect: return "aspectratio"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .detail: return "slider.horizontal.3"
        }
    }

    public var glyph: String {
        switch self {
        case .engine: return "%"
        case .aspect: return "#"
        case .size: return "+"
        case .detail: return "="
        }
    }

    /// Every one of these is a short list the value walks, so a press changes it rather than
    /// opening something to change it in.
    public var affordanceGlyph: String { "▾" }
}

/// Whether the render starts from words alone or from a picture the person handed it. This is
/// never asked as a question: it is read off whether anything is attached.
public enum ImageGenMode: String, Codable, Sendable, CaseIterable {
    case generate
    case edit

    public var label: String {
        switch self {
        case .generate: return Localized.text("Generate")
        case .edit: return Localized.text("Edit")
        }
    }
}
