import CoreGraphics
import Foundation
import QuartzCore
import TailscodeCore

/// The head drawn once for a look and a size, as an image every card that wears it shares.
///
/// A conversation of three hundred turns is three hundred cards, and a Metal render per card is
/// what a card must never cost. The picture is the same head in the same palette for every turn
/// that ended the same way, so it is made once: the renderer draws the whole design space at the
/// picture's size into two offscreen targets, the two are laid over one another into one bitmap,
/// and each card shows that bitmap cropped to the head's bounds with its own lights over it. The
/// renderer holds the process's textures only for the moment a picture is asked for and a few
/// seconds after, so they leave with the last card that wanted one.
@MainActor
final class BrainPicture {
    let image: CGImage
    /// The size of the whole design space in this image, in points.
    let designWidth: CGFloat
    let designHeight: CGFloat

    init(image: CGImage, designWidth: CGFloat, designHeight: CGFloat) {
        self.image = image
        self.designWidth = designWidth
        self.designHeight = designHeight
    }

    var footprint: Int { image.width * image.height * 4 }

    /// The part of the image the head's own bounds cover, as the layer's `contentsRect` reads it.
    static var cropRect: CGRect {
        let crop = NeuralStageMetrics.designCrop
        return CGRect(
            x: crop.x / NeuralDesign.width, y: crop.y / NeuralDesign.height,
            width: crop.width / NeuralDesign.width, height: crop.height / NeuralDesign.height)
    }
}

@MainActor
enum BrainPictures {
    struct Key: Equatable {
        let table: NeuralToneTable
        let frame: NeuralFrame
        let width: Int
        let height: Int
    }

    private final class Entry {
        let key: Key
        let picture: BrainPicture
        var used = 0
        init(key: Key, picture: BrainPicture) {
            self.key = key
            self.picture = picture
        }
    }

    private static var entries: [Entry] = []
    private static var waiting: [(key: Key, scale: CGFloat, callbacks: [(BrainPicture?) -> Void])] = []
    private static var tick = 0
    private static let capacity = 24
    private static var holds = false
    private static var releaseTicket = 0
    private static var renderer: NeuralHeadRenderer?
    private static var preparing = false
    private(set) static var renders = 0

    /// How many pictures are held and how big they are together, for the debug log.
    static var resident: (count: Int, bytes: Int) {
        (entries.count, entries.reduce(0) { $0 + $1.picture.footprint })
    }

    /// The picture for the head drawn over the whole design space `width` points wide, in this
    /// look. `done` runs on the main actor, at once when the picture is held, and with nil when the
    /// machine cannot draw one.
    static func picture(
        frame: NeuralFrame, palette: Palette, face: NeuralFace, width: CGFloat, scale: CGFloat,
        done: @escaping (BrainPicture?) -> Void
    ) {
        let table = NeuralToneTable(palette: palette, face: face)
        let height = width * CGFloat(NeuralDesign.height / NeuralDesign.width)
        let key = Key(
            table: table, frame: frame, width: max(1, Int((width * scale).rounded())),
            height: max(1, Int((height * scale).rounded())))
        if let held = entries.first(where: { $0.key == key }) {
            tick += 1
            held.used = tick
            done(held.picture)
            return
        }
        if let index = waiting.firstIndex(where: { $0.key == key }) {
            waiting[index].callbacks.append(done)
            return
        }
        waiting.append((key, scale, [done]))
        hold()
        guard NeuralMetalContext.shared?.isSupported == true else {
            finish(key, nil)
            return
        }
        guard !preparing else { return }
        preparing = true
        NeuralMetalContext.shared?.prepare { ready in
            preparing = false
            drain(ready: ready)
        }
    }

    private static func drain(ready: Bool) {
        guard ready, let context = NeuralMetalContext.shared else {
            for item in waiting { finish(item.key, nil) }
            return
        }
        if renderer == nil { renderer = NeuralHeadRenderer(context: context) }
        guard let renderer else {
            for item in waiting { finish(item.key, nil) }
            return
        }
        while let item = waiting.first {
            let key = item.key
            let pair = renderer.snapshot(
                frame: key.frame, table: key.table, time: 0, width: key.width, height: key.height)
            guard let pair, let image = compose(pair) else {
                finish(key, nil)
                continue
            }
            renders += 1
            let made = BrainPicture(
                image: image, designWidth: CGFloat(key.width) / item.scale,
                designHeight: CGFloat(key.height) / item.scale)
            tick += 1
            let entry = Entry(key: key, picture: made)
            entry.used = tick
            entries.append(entry)
            if entries.count > capacity {
                entries.sort { $0.used > $1.used }
                entries.removeLast(entries.count - capacity)
            }
            finish(key, made)
        }
        scheduleRelease()
    }

    private static func finish(_ key: Key, _ picture: BrainPicture?) {
        guard let index = waiting.firstIndex(where: { $0.key == key }) else { return }
        let callbacks = waiting.remove(at: index).callbacks
        for callback in callbacks { callback(picture) }
        if waiting.isEmpty { scheduleRelease() }
    }

    private static func hold() {
        guard !holds, let context = NeuralMetalContext.shared else { return }
        holds = true
        context.retain()
    }

    /// Loads the head's textures and compiles its pipelines on their own queues before the first
    /// card asks for a picture, so the first brain row of a launch is not waiting for them. It
    /// holds the context only until the usual few seconds after, like any picture.
    static func prewarm() {
        guard !warmed, BrainStore.isActive, NeuralMetalContext.shared?.isSupported == true else { return }
        warmed = true
        hold()
        NeuralMetalContext.shared?.prepare { _ in
            if waiting.isEmpty { scheduleRelease() }
        }
    }

    private static var warmed = false

    /// Lets go of the textures a few seconds after the last picture, which is long enough for the
    /// next card to share the same load and for an open to find them resident.
    private static func scheduleRelease() {
        releaseTicket += 1
        let ticket = releaseTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                guard releaseTicket == ticket, waiting.isEmpty, holds else { return }
                holds = false
                renderer = nil
                NeuralMetalContext.shared?.release()
            }
        }
    }

    /// Lets go of every picture, for a harness that wants the memory back.
    static func dropAll() { entries.removeAll() }

    /// The two surfaces laid over one another into one bitmap: the interior, opaque, and the front,
    /// premultiplied, over it.
    private static func compose(_ pair: NeuralSurfacePair) -> CGImage? {
        let width = pair.interior.width
        let height = pair.interior.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        for surface in [pair.interior, pair.front] {
            guard let layer = image(from: surface, space: space) else { return nil }
            context.draw(layer, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()
    }

    private static func image(from surface: NeuralSurface, space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(surface.bytes) as CFData) else { return nil }
        return CGImage(
            width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow, space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The two moments of a swell the live head is cross-faded between: the floor and the peak of the
/// breath or the heartbeat, found by looking rather than assumed, so the pair is right whatever
/// the activity's wave is authored as.
enum BrainSwellTimes {
    static func floorAndPeak(_ motion: NeuralMotion) -> (floor: TimeInterval, peak: TimeInterval) {
        let period: TimeInterval
        switch motion {
        case .breath: period = ActivityTuning.breathPeriod
        case .heartbeat: period = ActivityTuning.heartbeatPeriod
        case .sweep, .still: return (0, 0)
        }
        var low = (time: 0.0, level: Double.infinity)
        var high = (time: 0.0, level: -Double.infinity)
        let steps = 240
        for step in 0..<steps {
            let time = period * Double(step) / Double(steps)
            let level = motion.level(at: time)
            if level < low.level { low = (time, level) }
            if level > high.level { high = (time, level) }
        }
        return (low.time, high.time)
    }
}
