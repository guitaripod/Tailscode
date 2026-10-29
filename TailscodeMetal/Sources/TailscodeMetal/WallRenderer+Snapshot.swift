import CoreGraphics
import Foundation
@preconcurrency import Metal
import TailscodeCore

extension WallRenderer {
    /// Renders `scene` offscreen and reads it back, for a screenshot, a self-test or a tool.
    public static func image(
        of scene: WallScene, pixelWidth: Int, pixelHeight: Int, pointsPerPixel: Double, device: MTLDevice,
        time: TimeInterval = 12.3
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0, let renderer = WallRenderer(device: device),
            let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer()
        else { return nil }
        renderer.time = time
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        renderer.encode(
            scene, commandBuffer: buffer, pass: pass,
            drawableSize: CGSize(width: pixelWidth, height: pixelHeight), pointsPerPixel: pointsPerPixel)
        #if os(macOS)
        if !device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        #endif
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        return cgImage(from: texture)
    }

    private static func cgImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}
