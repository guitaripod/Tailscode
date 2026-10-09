#if DEBUG
    import CodingAgentKit
    import TailscodeCore
    import UIKit

    /// Pictures and shelves made on the spot for the screens that show them, so a photographed
    /// image library or viewer is full of varied, believable work without a machine behind it.
    /// Everything here is drawn from a fixed table, so every launch lands on the same shelf.
    @MainActor
    enum DuoFixtures {
        private struct Plate {
            let name: String
            let top: UInt32
            let bottom: UInt32
            let shape: Int
            let wide: Bool
        }

        private static let plates: [Plate] = [
            Plate(name: "lantern-market-0412", top: 0xF6A04D, bottom: 0x7B2D5B, shape: 0, wide: true),
            Plate(name: "glass-harbour-0413", top: 0x7FD1E8, bottom: 0x1B3A63, shape: 1, wide: true),
            Plate(name: "moss-cathedral-0414", top: 0xA6D96A, bottom: 0x1F4D3A, shape: 2, wide: false),
            Plate(name: "paper-comet-0415", top: 0xF4E6C8, bottom: 0xD2573F, shape: 3, wide: true),
            Plate(name: "night-tram-0416", top: 0x4B3F9E, bottom: 0x0E1233, shape: 4, wide: true),
            Plate(name: "copper-orchard-0417", top: 0xE8B27A, bottom: 0x6B3A22, shape: 0, wide: false),
            Plate(name: "tidal-library-0418", top: 0x5FC8B8, bottom: 0x174A56, shape: 1, wide: true),
            Plate(name: "violet-station-0419", top: 0xC7A3F2, bottom: 0x3A1D6B, shape: 2, wide: true),
            Plate(name: "salt-lighthouse-0420", top: 0xF2F2EE, bottom: 0x4F6F8F, shape: 3, wide: false),
            Plate(name: "ember-foundry-0421", top: 0xFF8A4C, bottom: 0x3B0F0F, shape: 4, wide: true),
            Plate(name: "pine-observatory-0422", top: 0x8CC2A5, bottom: 0x0F2B2E, shape: 0, wide: true),
            Plate(name: "rose-glasshouse-0423", top: 0xF7B6C6, bottom: 0x8A2B4F, shape: 1, wide: false),
            Plate(name: "indigo-ferry-0424", top: 0x7A8CF0, bottom: 0x141B54, shape: 2, wide: true),
            Plate(name: "amber-archive-0425", top: 0xFFD27A, bottom: 0x8A4B12, shape: 3, wide: true),
            Plate(name: "slate-arcade-0426", top: 0xB8C4CE, bottom: 0x2A3440, shape: 4, wide: false),
            Plate(name: "mint-clocktower-0427", top: 0xB5F0D6, bottom: 0x2E6E5A, shape: 0, wide: true),
            Plate(name: "plum-greenhouse-0428", top: 0xD9A0D0, bottom: 0x4A1A4F, shape: 1, wide: true),
            Plate(name: "sand-viaduct-0429", top: 0xF0DDB0, bottom: 0xA6683A, shape: 2, wide: false),
            Plate(name: "teal-bazaar-0430", top: 0x4FD6C9, bottom: 0x0C4A4F, shape: 3, wide: true),
            Plate(name: "coral-boathouse-0501", top: 0xFF9E8A, bottom: 0x7A2A3A, shape: 4, wide: true),
            Plate(name: "frost-conservatory-0502", top: 0xDDF1FF, bottom: 0x5A7FA6, shape: 0, wide: false),
            Plate(name: "garnet-reading-room-0503", top: 0xE0606E, bottom: 0x3F0F1E, shape: 1, wide: true),
            Plate(name: "olive-windmill-0504", top: 0xC9D27A, bottom: 0x4A5220, shape: 2, wide: true),
            Plate(name: "azure-funicular-0505", top: 0x6FB5FF, bottom: 0x0F2F6B, shape: 3, wide: false),
        ]

        private static func color(_ hex: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }

        private static func render(_ plate: Plate, longSide: CGFloat) -> Data {
            let size =
                plate.wide
                ? CGSize(width: longSide, height: longSide * 0.66)
                : CGSize(width: longSide * 0.66, height: longSide)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let ctx = context.cgContext
                let space = CGColorSpaceCreateDeviceRGB()
                let gradient = CGGradient(
                    colorsSpace: space,
                    colors: [color(plate.top).cgColor, color(plate.bottom).cgColor] as CFArray,
                    locations: [0, 1])!
                ctx.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width * 0.2, y: size.height),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
                let unit = min(size.width, size.height)
                switch plate.shape {
                case 0:
                    ctx.fillEllipse(
                        in: CGRect(
                            x: size.width * 0.58, y: size.height * 0.12, width: unit * 0.34,
                            height: unit * 0.34))
                    ctx.fill(CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3))
                case 1:
                    for step in 0..<5 {
                        let y = size.height * (0.45 + 0.1 * CGFloat(step))
                        ctx.fill(CGRect(x: 0, y: y, width: size.width, height: size.height * 0.04))
                    }
                case 2:
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width * 0.35, y: size.height * 0.4))
                    path.addLine(to: CGPoint(x: size.width * 0.62, y: size.height * 0.75))
                    path.addLine(to: CGPoint(x: size.width * 0.85, y: size.height * 0.5))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.close()
                    ctx.addPath(path.cgPath)
                    ctx.fillPath()
                case 3:
                    for ring in 1...4 {
                        let side = unit * 0.2 * CGFloat(ring)
                        ctx.strokeEllipse(
                            in: CGRect(
                                x: size.width * 0.5 - side / 2, y: size.height * 0.45 - side / 2,
                                width: side, height: side))
                    }
                default:
                    for column in 0..<6 {
                        let height = size.height * (0.25 + 0.08 * CGFloat((column * 5) % 7))
                        ctx.fill(
                            CGRect(
                                x: size.width * (0.08 + 0.15 * CGFloat(column)),
                                y: size.height - height, width: size.width * 0.1, height: height))
                    }
                }
            }
            return image.pngData() ?? Data()
        }

        static func gallery(count: Int = 6) -> [GalleryImage] {
            plates.prefix(count).map { plate in
                GalleryImage(
                    id: plate.name,
                    file: FileReference(
                        mime: "image/png", filename: plate.name + ".png"),
                    localData: render(plate, longSide: 1600))
            }
        }

        static func library() -> ImageLibrary {
            let endpoint = ImageGenEndpoint(host: "studio.tailnet-demo.ts.net")
            let cache = ImageGenLibraryCache(endpoint: endpoint)
            let items = plates.map { ImageGenLibraryItem(filename: $0.name + ".png") }
            for (plate, item) in zip(plates, items) {
                let file = cache.thumbnailURL(item, format: .webp)
                try? render(plate, longSide: 360).write(to: file, options: .atomic)
            }
            cache.store(listing: items)
            return ImageLibrary(endpoint: endpoint)
        }
    }
#endif
