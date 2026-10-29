#if os(macOS)
import Foundation
import Metal
import os
import TailscodeCore
import TailscodeMetal

/// Median GPU time of the iPad landscape attention wall at two pixels per point, and of the same wall
/// with parts of it taken away, to say where a frame's time goes.
enum Bench {
    static let frames = 120

    static func run(device: MTLDevice, theme: AppTheme, now: Date) {
        guard let source = AgentDemo.wallScenes(now: now).first(where: { $0.name == "attention" })?.wall,
            let screen = Screens.all.first(where: { $0.name == "ipad-landscape" }),
            let renderer = WallRenderer(device: device), let queue = device.makeCommandQueue()
        else { return }
        let staged = Staging.stage(source, screen: screen, theme: theme, now: now)
        let width = Int(screen.width * Staging.scale)
        let height = Int(screen.height * Staging.scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        renderer.time = Staging.time
        let scene = staged.scene
        print(
            "\(device.name) \(width)x\(height) plates \(scene.plates.count) bars \(scene.bars.count) glyphs \(scene.glyphs.count) glows \(scene.glows.count) dots \(scene.dots.count) lights \(scene.lights.count) ripples \(scene.ripples.count)"
        )
        func measure(_ label: String, _ scene: WallScene) {
            let samples = OSAllocatedUnfairLock<[Double]>(initialState: [])
            var last: MTLCommandBuffer?
            for _ in 0..<(frames * 2) {
                guard let buffer = queue.makeCommandBuffer() else { return }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                renderer.encode(
                    scene, commandBuffer: buffer, pass: pass,
                    drawableSize: CGSize(width: width, height: height), pointsPerPixel: 1 / Staging.scale)
                buffer.addCompletedHandler { done in
                    let seconds = done.gpuEndTime - done.gpuStartTime
                    samples.withLock { $0.append(seconds) }
                }
                buffer.commit()
                last = buffer
            }
            last?.waitUntilCompleted()
            usleep(20000)
            var taken = samples.withLock { Array($0.suffix(frames)) }
            taken.sort()
            print(
                String(
                    format: "%@ median GPU %.3f ms  min %.3f  max %.3f  over %d back-to-back frames",
                    label.padding(toLength: 18, withPad: " ", startingAt: 0), taken[taken.count / 2] * 1000,
                    taken.first! * 1000, taken.last! * 1000, taken.count))
        }
        measure("full", scene)
        var only = scene
        only.plates = []
        only.bars = []
        only.glyphs = []
        only.glows = []
        only.dots = []
        measure("ground+lights+rip", only)
        var lightsOnly = only
        lightsOnly.ripples = []
        measure("ground+lights", lightsOnly)
        var ripplesOnly = only
        ripplesOnly.lights = []
        measure("ground+ripples", ripplesOnly)
        var quads = scene
        quads.lights = []
        quads.ripples = []
        measure("no light/ripples", quads)
        var bare = scene
        bare.lights = []
        bare.ripples = []
        bare.plates = []
        bare.bars = []
        bare.glyphs = []
        bare.glows = []
        bare.dots = []
        measure("ground only", bare)
        bare.gridAlpha = 0
        bare.tintAlpha = 0
        bare.vignette = 0
        measure("ground no grid", bare)
    }
}
#endif
