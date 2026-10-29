import CoreGraphics
import Foundation
import Metal
import Testing
import TailscodeCore

@testable import TailscodeMetal

@Suite struct WallRendererTests {
    @Test func busyDemoRendersAWallDistinctFromItsGround() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let now = Date()
        let busy = try #require(AgentDemo.wallScenes(now: now).first { $0.name == "busy" })
        let style = WallStyle.studio
        let width = 951.0
        let height = 669.0
        let reading = WallLayout.reading(width: width, height: height, safe: .zero, fold: nil, style: style)
        let wall = busy.wall.reflowed(
            aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages)
        let layout = WallLayout.make(
            width: width, height: height, safe: .zero, fold: nil, wall: wall, style: style)
        let motes = WallMotes(width: width, height: height, seed: 7)
        let theme = AppTheme.all.first { $0.id == "rosepine" } ?? AppTheme.all[0]
        let input = WallSceneInput(
            wall: wall, layout: layout, palette: WallPalette.current(theme: theme), style: style, t: 12.3,
            now: now, motes: motes)
        let scene = WallScene.build(input)
        let image = try #require(
            WallRenderer.image(
                of: scene, pixelWidth: 951, pixelHeight: 669, pointsPerPixel: 1, device: device))
        #expect(image.width == 951 && image.height == 669)

        let tile = try #require(layout.tiles.first)
        let inside = try pixel(image, x: Int(tile.midX), y: Int(tile.midY))
        let ground = try pixel(image, x: 2, y: 2)
        let spread = zip(inside, ground).map { abs(Int($0) - Int($1)) }.reduce(0, +)
        #expect(spread > 6)
        #expect(ground.contains { $0 > 0 })
    }

    @Test func rendererBuildsItsPipelinesAndBuffers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WallRenderer(device: device))
        #expect(renderer.lastGPUTime == 0)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Array(bytes[0..<3])
    }
}
