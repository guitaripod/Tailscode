import AppKit
import ImageIO
import TailscodeCore
import UniformTypeIdentifiers

/// Every state the Studio has, put on a studio without a machine to make one happen. A render is a
/// minute or two of another machine's card, so the states between pressing Generate and holding a
/// picture cannot be reached in a build loop — and they are exactly the states worth looking at.
/// The pictures are drawn here with Core Graphics, so nothing crosses a network and nothing a person
/// made is touched: the shelf is a cache for a machine that exists only on this screen, and the
/// preference store is never written.
@MainActor
enum StudioDemo {
    /// The names `--open studio:<state>` understands.
    static let states = ["empty", "drafting", "painting", "done", "failed", "rewrite"]

    static let endpoint = ImageGenEndpoint(host: "arch.ts.net")

    private static let words = [
        "a lighthouse on a cliff at dusk, waves breaking below, last light on the lamp room",
        "a ceramic teapot on transparency, soft highlight down the left of the body",
        "a chalkboard menu on a whitewashed brick wall, warm amber and charcoal",
        "an elderly fisherman in a yellow oilskin against a grey harbour at dawn",
        "an exploded diagram of a mechanical wristwatch movement on off-white paper",
        "a night sky over a dark ridge, one bright star low on the horizon",
        "a bowl of citrus on a wooden table in low sun",
    ]

    static func apply(_ state: String, to studio: MacImageStudio) {
        let library = seededLibrary()
        let pictures = (0..<words.count).map { index in
            Self.bokeh(seed: index, width: 1200, height: 800)
        }
        var slot = ImageGenSlot(endpoint: endpoint)
        slot.setEngine(.quality)
        slot.setAspect(.landscape)
        slot.setSize(.standard)
        slot.promptDraft = words[0]
        var sighting = ImageGenSighting(
            endpoint: endpoint,
            health: ImageGenHealth(reachable: true, missingModels: [], version: "0.36", running: 0))
        var progress: ImageGenProgress?
        var sketch: CGImage?
        var started: Date?
        var bitmaps: [String: CGImage] = [:]
        var rewrite: ImageGenRewriteDraft?
        let name = (state.split(separator: ":").first).map(String.init) ?? state
        switch name {
        case "drafting":
            if let path = write(pictures[2], named: "reference") {
                slot.hold(ImageGenReference(path: path))
            }
        case "painting":
            slot.begin(prompt: words[0])
            progress = ImageGenProgress(stage: .painting, step: 12, steps: 28, fraction: 0.43)
            sketch = Self.bokeh(seed: 0, width: 360, height: 240, soft: true)
            started = Date().addingTimeInterval(-19)
        case "done":
            if let path = write(pictures[0], named: "made") {
                let picture = ImageGenPicture(
                    path: path, prompt: words[0], engine: .quality, mode: .generate,
                    aspect: .landscape, size: .standard, seconds: 41, seed: 481_723, steps: 28,
                    remoteName: library.items.first?.id)
                slot.finish(picture)
                bitmaps[path] = pictures[0]
            }
        case "rewrite":
            slot.promptDraft = "a lighthouse on a cliff at dusk"
            rewrite = ImageGenRewriteDraft(
                original: slot.promptDraft,
                written:
                    "The image is a wide realistic photograph of a white lighthouse on a granite cliff at dusk, "
                    + "waves breaking on the rocks below. In the centre of the frame, the tower stands against a "
                    + "violet sky streaked with amber, its lamp room lit. Across the lower third, white spray "
                    + "climbs the rock. The lighting is the last low light from the left, leaving long cool shadows.",
                aspect: .landscape, phase: .landed,
                helper: ImageGenHelper(address: "http://arch.ts.net:8081", model: "qwen38", label: "Qwen 3.8 27B"))
        case "failed":
            sighting = ImageGenSighting(
                endpoint: endpoint,
                health: ImageGenHealth(
                    reachable: true, missingModels: [ImageGenModelFile.qwenDiffusion.path],
                    version: "0.36", running: 0))
            slot.fail(
                prompt: words[0],
                reason: ImageGenWords.cannotRender(engine: .quality, machine: endpoint.shortName))
        default:
            slot.promptDraft = ""
        }
        studio.stage(
            slot: slot, sighting: sighting, progress: progress, sketch: sketch, started: started,
            bitmaps: bitmaps, library: library, rewrite: rewrite)
    }

    /// The machine's folder as a cache the library reads before it asks anybody: a listing, the
    /// head of each file and a small copy of each picture, for a host that exists only here.
    private static func seededLibrary() -> MacImageLibrary {
        let cache = ImageGenLibraryCache(endpoint: endpoint)
        var items: [ImageGenLibraryItem] = []
        let now = Date()
        for (index, text) in words.enumerated() {
            let item = ImageGenLibraryItem(filename: String(format: "tailscode_%05d_.png", 71 - index))
            items.append(item)
            let big = bokeh(seed: index, width: 1200, height: 800)
            let small = bokeh(seed: index, width: 256, height: 171)
            if let data = png(big) { try? data.write(to: cache.originalURL(item), options: .atomic) }
            if let data = png(small) {
                try? data.write(to: cache.thumbnailURL(item, format: .webp), options: .atomic)
            }
            cache.store(
                ImageGenLibraryFacts(
                    bytes: 1_200_000 + index * 31_000,
                    modifiedAt: now.addingTimeInterval(-Double(index) * 5_400 - 720),
                    width: 1200, height: 800,
                    recipe: ComfyRecipe(
                        prompt: text, seed: UInt64(481_723 + index), steps: 28,
                        engine: .quality)), for: item)
        }
        cache.store(listing: items, at: now)
        return MacImageLibrary(endpoint: endpoint)
    }

    static func write(_ image: CGImage, named name: String) -> String? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-studio-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".png")
        guard let data = png(image), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.path
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A field of soft light: a gradient with overlapping translucent discs, a different one for
    /// every seed. `soft` smooths it further, which is what a sampler's early sketch looks like.
    static func bokeh(seed: Int, width: Int, height: Int, soft: Bool = false) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hues: [(CGFloat, CGFloat)] = [
            (0.06, 0.62), (0.5, 0.55), (0.92, 0.6), (0.64, 0.55), (0.2, 0.6), (0.08, 0.7), (0.62, 0.35),
        ]
        let (hue, saturation) = hues[seed % hues.count]
        func colour(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
            NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: a).cgColor
        }
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [colour(hue + 0.05, saturation, 0.35), colour(hue, saturation * 0.8, 0.85)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: 0), options: [])
        var generator = SeededGenerator(seed: UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15)
        let count = soft ? 7 : 16
        for _ in 0..<count {
            let radius = CGFloat.random(in: 0.08...(soft ? 0.34 : 0.26), using: &generator) * CGFloat(min(width, height))
            let x = CGFloat.random(in: 0...1, using: &generator) * CGFloat(width)
            let y = CGFloat.random(in: 0...1, using: &generator) * CGFloat(height)
            context.setFillColor(
                colour(hue + CGFloat.random(in: -0.04...0.08, using: &generator), saturation * 0.7, CGFloat.random(in: 0.55...0.95, using: &generator), soft ? 0.5 : 0.32))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        return context.makeImage()!
    }
}

/// A generator that answers the same numbers for the same seed, so a demo picture is the same
/// picture every time it is drawn.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x1234_5678 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
