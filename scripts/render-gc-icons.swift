import AppKit
import Foundation

/// Renders the Game Center artwork set: one 1024×1024 PNG per catalog entry, an SF Symbol on
/// a hue-spaced gradient so the shelf reads as one family. Driven by asc-gamecenter.py:
/// `swift render-gc-icons.swift /tmp/gc-catalog.json out-dir`.
struct Entry: Decodable {
    let slug: String
    let symbol: String
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-gc-icons.swift catalog.json out-dir\n".utf8))
    exit(2)
}
let entries = try JSONDecoder().decode(
    [Entry].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let outDir = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let side: CGFloat = 1024
for (index, entry) in entries.enumerated() {
    let hue = (Double(index) * 0.618033988749895).truncatingRemainder(dividingBy: 1)
    let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1)
    let bottom = NSColor(hue: hue, saturation: 0.75, brightness: 0.28, alpha: 1)

    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    {
        let size = symbol.size
        let scale = min(560 / max(size.width, size.height), 8)
        let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
        let origin = NSPoint(
            x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        symbol.draw(
            in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver,
            fraction: 1)
    }
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("render failed: \(entry.slug)\n".utf8))
        exit(1)
    }
    try png.write(to: outDir.appendingPathComponent("\(entry.slug).png"))
    print("rendered \(entry.slug).png")
}
