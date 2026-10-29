#if os(macOS)
import AppKit
import Foundation
import Metal
import TailscodeCore
import TailscodeMetal

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("no Metal device\n".utf8))
    exit(1)
}
let arguments = CommandLine.arguments.dropFirst()
let now = Date()
let theme = AppTheme.all.first { $0.id == "rosepine" } ?? AppTheme.all[0]

if arguments.first == "--bench" {
    Bench.run(device: device, theme: theme, now: now)
    exit(0)
}

guard let directory = arguments.first else {
    FileHandle.standardError.write(Data("usage: wall-render <out-dir> | --bench\n".utf8))
    exit(2)
}
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

var written = 0
for (name, source) in AgentDemo.wallScenes(now: now) {
    for screen in Screens.all {
        let staged = Staging.stage(source, screen: screen, theme: theme, now: now)
        let pixelWidth = Int(screen.width * Staging.scale)
        let pixelHeight = Int(screen.height * Staging.scale)
        guard
            let raw = WallRenderer.image(
                of: staged.scene, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                pointsPerPixel: 1 / Staging.scale, device: device, time: Staging.time),
            let image = Overlay.annotate(raw, staged: staged, scale: Staging.scale)
        else {
            FileHandle.standardError.write(Data("failed: \(name) \(screen.name)\n".utf8))
            exit(1)
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(screen.name).png")
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: url)
        written += 1
    }
}
print("wrote \(written) images to \(directory)")
#endif
