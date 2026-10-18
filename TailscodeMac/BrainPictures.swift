import AppKit
import TailscodeCore

/// The head at rest as one picture, shared by every card and by the move.
///
/// A card is recognised by which parts of the head are lit, and the head under the lights is the
/// same dark picture for every card of a look, so it is rendered once by the Metal renderer
/// offscreen (`NeuralHeadRenderer.snapshot`), composed into one image with its glass, and kept by
/// look and by the few things that change it (the eye's tone, the effort bars, the ribs). A
/// conversation of three hundred turns costs the handful of pictures its looks need, never a
/// render per card.
@MainActor
enum BrainPictures {
    /// The size the one picture is rendered at, in pixels, over the head's whole design space. The
    /// largest stage is about 380 points across, so this is sharp at 2x and the card minifies it.
    static let pixelWidth = 768
    static var pixelHeight: Int {
        Int((Double(pixelWidth) * NeuralDesign.height / NeuralDesign.width).rounded())
    }

    private static var images: [String: CGImage] = [:]
    private static var order: [String] = []
    private static var waiting: [String: [@MainActor (CGImage?) -> Void]] = [:]
    private static var holdTimer: Timer?
    private static var holding = false
    private static var renderer: NeuralHeadRenderer?
    nonisolated(unsafe) static var rendered = 0

    /// A harness that cannot wait for a callback (it runs inside one) asks for the picture to be
    /// made on the spot.
    nonisolated(unsafe) static var rendersSynchronously = false
    private static let capacity = 12

    /// What the frame shows when the head is at rest under a card: the model's frame with every
    /// zone back at its rest brightness, because a card's zones are the lights over the picture.
    static func restFrame(of model: NeuralBrainModel) -> NeuralFrame {
        var frame = model.frame(time: 0, reduceMotion: true)
        for index in 0..<NeuralZone.allCases.count {
            frame.intensity[index] = NeuralFrame.restIntensity[index]
            frame.toneOverride[index] = nil
        }
        frame.intensity[NeuralChannel.link.rawValue] = NeuralFrame.restIntensity[NeuralChannel.link.rawValue]
        frame.ripple = 0
        frame.active = nil
        frame.sweep = 0
        frame.sweepAmount = 0
        frame.orbit = false
        frame.settled = true
        return frame
    }

    static func key(palette: Palette, frame: NeuralFrame, face: NeuralFace) -> String {
        "\(palette.name)|\(palette.isDark)|\(palette.canvas)|\(palette.accent)|\(face.hueHex(isDark: palette.isDark))|"
            + "\(frame.intensity)|\(frame.toneOverride)|\(frame.effort)|\(frame.hollow)|\(frame.rainbow)|"
            + "\(Int(frame.ribs * 20))"
    }

    /// The cached picture for a look, or nil while it is being made.
    static func cached(palette: Palette, frame: NeuralFrame, face: NeuralFace) -> CGImage? {
        images[key(palette: palette, frame: frame, face: face)]
    }

    /// Asks for the picture of a look; `completion` runs on the main actor, at once when the
    /// picture is already held.
    static func picture(
        palette: Palette, frame: NeuralFrame, face: NeuralFace,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        let id = key(palette: palette, frame: frame, face: face)
        if let held = images[id] {
            touch(id)
            completion(held)
            return
        }
        if waiting[id] != nil {
            waiting[id]?.append(completion)
            return
        }
        waiting[id] = [completion]
        guard let metal = NeuralMetalContext.shared, metal.isSupported else {
            finish(id, nil)
            return
        }
        hold(metal)
        if rendersSynchronously {
            guard metal.prepareSynchronously() else {
                finish(id, nil)
                return
            }
            if renderer == nil { renderer = NeuralHeadRenderer(context: metal) }
            let table = NeuralToneTable(palette: palette, face: face)
            let made = renderer.flatMap { renderer in
                renderer.snapshot(
                    frame: frame, table: table, time: 0, width: pixelWidth, height: pixelHeight)
            }.flatMap { compose($0) }
            rendered += 1
            finish(id, made)
            return
        }
        metal.prepare { ready in
            guard ready else {
                finish(id, nil)
                return
            }
            if renderer == nil { renderer = NeuralHeadRenderer(context: metal) }
            let table = NeuralToneTable(palette: palette, face: face)
            let made = renderer.flatMap { renderer in
                renderer.snapshot(
                    frame: frame, table: table, time: 0, width: pixelWidth, height: pixelHeight)
            }.flatMap { compose($0) }
            rendered += 1
            finish(id, made)
        }
    }

    private static func finish(_ id: String, _ image: CGImage?) {
        if let image {
            images[id] = image
            touch(id)
            while order.count > capacity, let oldest = order.first {
                order.removeFirst()
                images[oldest] = nil
            }
        }
        let callbacks = waiting.removeValue(forKey: id) ?? []
        for callback in callbacks { callback(image) }
    }

    private static func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    /// Keeps the process's textures resident while pictures are being asked for, and lets them go
    /// a few seconds after the last ask.
    private static func hold(_ metal: NeuralMetalContext) {
        if !holding {
            holding = true
            metal.retain()
        }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard holding, waiting.isEmpty else { return }
                holding = false
                renderer = nil
                NeuralMetalContext.shared?.release()
            }
        }
    }

    /// Forgets every picture, for a look that changed under them.
    static func forgetAll() {
        images = [:]
        order = []
    }

    private static func compose(_ pair: NeuralSurfacePair) -> CGImage? {
        guard let interior = image(pair.interior), let front = image(pair.front),
            let context = CGContext(
                data: nil, width: pair.interior.width, height: pair.interior.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pair.interior.width, height: pair.interior.height)
        context.draw(interior, in: rect)
        context.draw(front, in: rect)
        return context.makeImage()
    }

    private static func image(_ surface: NeuralSurface) -> CGImage? {
        guard surface.width > 0, surface.height > 0,
            let provider = CGDataProvider(data: Data(surface.bytes) as CFData)
        else { return nil }
        return CGImage(
            width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The head's picture as a layer tree in the design's own units, so one affine transform places it
/// on a card, carries it through the move and lands it on the stage: the rest image, one soft
/// light per zone the turn used, and the rings a failure leaves. It is the one traveller.
///
/// The container is 576 by 420 design units (the head's own bounds) and clips the image, which is
/// 640 units wide and starts 64 units to the left. A transform scales it, so the lights and rings
/// scale with the head and never drift off it.
@MainActor
final class BrainPictureLayer {
    let container = CALayer()
    private let imageLayer = CALayer()
    private let lightGroup = CALayer()
    private let ringGroup = CALayer()
    private let sweepLayer = CAGradientLayer()
    private var lightLayers: [NeuralZone: CAGradientLayer] = [:]
    private var ringLayers: [CAShapeLayer] = []
    private var signature = ""
    private(set) var hasImage = false

    /// How much of the card's light the picture keeps: the lights are the card's whole identity,
    /// and at full strength they hide the head they are lit on.
    static let lightGain = 0.74

    init() {
        let crop = NeuralStageMetrics.designCrop
        container.anchorPoint = .zero
        container.bounds = CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
        container.masksToBounds = true
        imageLayer.frame = CGRect(
            x: -crop.x, y: 0, width: NeuralDesign.width, height: NeuralDesign.height)
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.minificationFilterBias = 0
        container.addSublayer(imageLayer)
        lightGroup.frame = container.bounds
        lightGroup.compositingFilter = "screenBlendMode"
        container.addSublayer(lightGroup)
        ringGroup.frame = container.bounds
        container.addSublayer(ringGroup)
        sweepLayer.frame = container.bounds
        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepLayer.opacity = 0
        sweepLayer.compositingFilter = "screenBlendMode"
        container.addSublayer(sweepLayer)
    }

    func setImage(_ image: CGImage?, scale: CGFloat, fading: Bool = false) {
        if fading, hasImage, image != nil, ActivityPulse.motionAllowed {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = NeuralCardSettle.duration
            imageLayer.add(fade, forKey: "brain.fade")
        }
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        hasImage = image != nil
        container.backgroundColor = hasImage ? nil : NSColor.black.withAlphaComponent(0.06).cgColor
    }

    /// Places the picture so the head's bounds fill `rect`, in the row's own (flipped) space.
    func place(_ rect: NeuralRect, overscale: Double = 1) {
        let crop = NeuralStageMetrics.designCrop
        let scale = rect.width / crop.width
        container.position = CGPoint(x: rect.x, y: rect.y)
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        if overscale != 1 {
            let dx = crop.width * scale * (overscale - 1) / 2
            let dy = crop.height * scale * (overscale - 1) / 2
            transform = transform.scaledBy(x: overscale, y: overscale)
            container.position = CGPoint(x: rect.x - dx, y: rect.y - dy)
        }
        container.setAffineTransform(transform)
    }

    func setCornerRadius(_ radius: CGFloat, designScale: CGFloat) {
        container.cornerRadius = designScale > 0 ? radius / designScale : 0
        container.cornerCurve = .continuous
    }

    /// The lights and rings of a card, in the tones the head is lit in, at `lift` of their card
    /// strength (1 on a card, 0 once the stage has taken the head over).
    func show(
        card: NeuralBrainCard, inks: BrainInks, hovered: Bool, lift: Double = 1,
        ringLift: Double? = nil, liveZone: NeuralZone? = nil, liveMotion: NeuralMotion = .still
    ) {
        let key = "\(card.lights.map { "\($0.zone.rawValue):\($0.strength):\($0.radius):\($0.ringStyle)" })|\(inks.palette.name)|\(inks.palette.isDark)|\(hovered)|\(liveZone?.rawValue ?? -1)|\(liveMotion)"
        let needsRebuild = key != signature
        signature = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        lightGroup.opacity = Float(max(0, min(1, lift)) * Self.lightGain)
        ringGroup.opacity = Float(max(0, min(1, ringLift ?? lift)))
        guard needsRebuild else { return }
        for layer in lightLayers.values { layer.removeFromSuperlayer() }
        for layer in ringLayers { layer.removeFromSuperlayer() }
        lightLayers = [:]
        ringLayers = []
        for light in card.lights {
            let tone = inks.dome(light.zone)
            let strength = CGFloat(light.strength(hovered: hovered))
            let layer = CAGradientLayer()
            layer.type = .radial
            layer.colors = [
                tone.withAlphaComponent(strength).cgColor,
                tone.withAlphaComponent(strength * 0.45).cgColor,
                tone.withAlphaComponent(0).cgColor,
            ]
            layer.locations = [0, 0.55, 1]
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            let crop = NeuralStageMetrics.designCrop
            let radius = CGFloat(light.radius)
            layer.frame = CGRect(
                x: CGFloat(light.center.x - crop.x) - radius, y: CGFloat(light.center.y) - radius,
                width: radius * 2, height: radius * 2)
            lightGroup.addSublayer(layer)
            lightLayers[light.zone] = layer
            if light.zone == liveZone { BrainMotion.breathe(layer, liveMotion) }
            guard light.ringStyle != .none, let ring = light.ring else { continue }
            let shape = CAShapeLayer()
            let ringRadius = CGFloat(ring.radius)
            shape.path = CGPath(
                ellipseIn: CGRect(x: -ringRadius, y: -ringRadius, width: ringRadius * 2, height: ringRadius * 2),
                transform: nil)
            shape.position = CGPoint(x: CGFloat(light.center.x - crop.x), y: CGFloat(light.center.y))
            shape.fillColor = nil
            let ink = inks.page(light.ringTone, face: .unknown)
            shape.strokeColor = ink.cgColor
            shape.lineWidth = max(1.4, CGFloat(ring.strokeWidth) * 0.8)
            if light.ringStyle == .repairedDashed { shape.lineDashPattern = [22, 16] }
            ringGroup.addSublayer(shape)
            ringLayers.append(shape)
        }
    }

    /// The sweep's band across the head: `phase` runs 0 to 1 over its one crossing at `amount`.
    func sweep(phase: Double, amount: Double, tone: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard amount > 0.001 else {
            sweepLayer.opacity = 0
            return
        }
        let center = CGFloat(-0.2 + 1.4 * phase)
        let width: CGFloat = 0.22
        sweepLayer.colors = [
            tone.withAlphaComponent(0).cgColor, tone.withAlphaComponent(1).cgColor,
            tone.withAlphaComponent(0).cgColor,
        ]
        sweepLayer.locations = [
            NSNumber(value: Double(max(0, center - width))), NSNumber(value: Double(min(1, max(0, center)))),
            NSNumber(value: Double(min(1, center + width))),
        ]
        sweepLayer.opacity = Float(amount)
    }

    /// Whether any light is breathing, for the harness.
    var isBreathing: Bool { lightLayers.values.contains { BrainMotion.isBreathing($0) } }
    var lightCount: Int { lightLayers.count }
    var ringCount: Int { ringLayers.count }
}
