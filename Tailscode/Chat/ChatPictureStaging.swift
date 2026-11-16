#if DEBUG
    import CodingAgentKit
    import UIKit

    /// Pictures an agent made, put into a demo transcript so a strip can be photographed with no
    /// server holding any. `TAILSCODE_STAGE_PICTURES=<count>` appends one strip of that many
    /// generated pictures — landscape, portrait, square and wide in turn — and stores their pixels
    /// where the transcript looks for them, so nothing asks a backend for bytes.
    @MainActor
    enum ChatPictureStaging {
        static var count: Int {
            Int(ProcessInfo.processInfo.environment["TAILSCODE_STAGE_PICTURES"] ?? "") ?? 0
        }

        /// `TAILSCODE_STAGE_LINKS=<count>` appends a rail of that many addresses, so the rail that
        /// folds and unfolds can be photographed in a demo whose prose mentions only one.
        static func linkRail() -> ChatRow? {
            let count = Int(ProcessInfo.processInfo.environment["TAILSCODE_STAGE_LINKS"] ?? "") ?? 0
            guard count > 0 else { return nil }
            let hosts = ["github.com/swiftlang/swift", "docs.github.com/en/actions", "datatracker.ietf.org/doc/rfc6298", "www.rfc-editor.org/rfc/rfc8085"]
            let addresses = (0..<count).map { "https://" + hosts[$0 % hosts.count] + ($0 >= hosts.count ? "/\($0)" : "") }
            return ChatRow(
                id: "staged:rail", messageID: "staged", role: .assistant,
                content: .linkRail(LinkRailRun(addresses: addresses)))
        }

        static func row() -> ChatRow? {
            let wanted = count
            guard wanted > 0 else { return nil }
            let files = (0..<wanted).map { index in
                FileReference(
                    path: "/staged/shot-\(index + 1).png", mime: "image/png",
                    url: "staged://picture/\(index)", filename: "shot-\(index + 1).png")
            }
            for (index, file) in files.enumerated() {
                let drawn = picture(index)
                AttachmentImageStore.shared.store(drawn, for: file, data: drawn.pngData())
            }
            return ChatRow(
                id: "staged:pictures", messageID: "staged", role: .assistant,
                content: .pictures(files))
        }

        /// `TAILSCODE_OPEN_PICTURE=<tile>[:<page>[:<seconds>]]` presses a tile of the staged strip
        /// four seconds after the chat opens, as a hand would, then turns to a page if one is
        /// named and closes after the seconds given, so the viewer's way out of a tile and its way
        /// home can be filmed with nothing touching the screen.
        static func drive(_ chat: ChatViewController) {
            guard let plan = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_PICTURE"] else {
                return
            }
            let fields = plan.split(separator: ":").map(String.init)
            let tile = fields.first.flatMap(Int.init) ?? 0
            let page = fields.count > 1 ? Int(fields[1]) : nil
            let close = fields.count > 2 ? Double(fields[2]) : nil
            Task { [weak chat] in
                try? await Task.sleep(for: .seconds(4))
                guard let chat,
                    let strip = chat.collectionView.visibleCells
                        .compactMap({ $0 as? PictureGalleryCell }).first
                else { return }
                chat.pictureGalleryCell(strip, didTapPictureAt: tile)
                guard let close else { return }
                try? await Task.sleep(for: .seconds(1.5))
                let viewer = chat.presentedViewController as? ImageViewerViewController
                if let page { viewer?.stagedTurn(to: page) }
                try? await Task.sleep(for: .seconds(close))
                viewer?.stagedClose()
            }
        }

        private static func picture(_ index: Int) -> UIImage {
            let sizes = [CGSize(width: 1600, height: 1000), CGSize(width: 900, height: 1400),
                CGSize(width: 1200, height: 1200), CGSize(width: 2000, height: 700)]
            let hues: [CGFloat] = [0.58, 0.08, 0.33, 0.78]
            let size = sizes[index % sizes.count]
            let hue = hues[index % hues.count]
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                let colors = [
                    UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                    UIColor(hue: hue, saturation: 0.8, brightness: 0.45, alpha: 1).cgColor,
                ]
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                    locations: [0, 1])!
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                let label = "\(index + 1)" as NSString
                label.draw(
                    at: CGPoint(x: size.width * 0.08, y: size.height * 0.06),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: size.height * 0.4, weight: .heavy),
                        .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                    ])
            }
        }
    }
#endif
