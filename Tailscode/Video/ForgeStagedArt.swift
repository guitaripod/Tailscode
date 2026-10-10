#if DEBUG
    import UIKit

    /// Real pictures for a staged video board, so a photograph of the forge shows what a renderer
    /// would have drawn instead of a gradient. `TAILSCODE_FORGE_ART` names a folder of pictures
    /// named by what they show (`cat-roof.png`); nothing is read, and nothing changes, when it is
    /// unset, so every other staged state keeps its own stand-ins.
    enum ForgeStagedArt {
        static var folder: URL? {
            ProcessInfo.processInfo.environment["TAILSCODE_FORGE_ART"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        }

        static var isOn: Bool { folder != nil }

        static func image(named name: String) -> UIImage? {
            guard let folder else { return nil }
            return UIImage(contentsOfFile: folder.appendingPathComponent("\(name).png").path)
        }

        /// What each staged history clip was made from, newest first; nil is the render that
        /// failed and so has no picture.
        static let shelf: [(words: String, art: String?)] = [
            ("a cat asleep on a warm tiled roof, late afternoon light", "cat-roof"),
            ("paper boats floating down a rain-wet street at night, neon reflections", "paper-boats"),
            ("a lighthouse on a cliff at dusk, waves breaking below", nil),
            ("a lighthouse on a cliff at dusk, last light on the lamp room", "lighthouse"),
            ("a red fox crossing a birch forest at first light, low mist", "fox"),
            ("a bowl of ramen with rising steam, moody kitchen light", "ramen"),
        ]

        /// The middle of a picture cut to a shape, as the render's own frame is shaped.
        static func cropped(_ image: UIImage, toAspect aspect: CGFloat) -> UIImage {
            guard let cg = image.cgImage else { return image }
            let width = CGFloat(cg.width)
            let height = CGFloat(cg.height)
            let cropWidth = min(width, height * aspect)
            let cropHeight = cropWidth / aspect
            let rect = CGRect(
                x: (width - cropWidth) / 2, y: (height - cropHeight) / 2, width: cropWidth,
                height: cropHeight)
            return cg.cropping(to: rect).map { UIImage(cgImage: $0) } ?? image
        }

        /// The picture scaled down to a width, the way the machine's own sketch frames arrive.
        static func scaled(_ image: UIImage, toWidth width: CGFloat) -> UIImage {
            let size = CGSize(width: width, height: width * image.size.height / image.size.width)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
#endif
