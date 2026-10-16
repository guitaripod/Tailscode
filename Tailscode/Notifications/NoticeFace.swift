import UIKit
import UserNotifications

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// The face a notice wears, drawn the same by the app, the notification service and the long look.
///
/// A rounded square in the tone of what happened with its symbol on it, as the Linux desktop draws
/// its own. The colours are the system's rather than the app theme's: a notification is the
/// system's chrome, drawn by processes that never see the theme, and a face that changed colour
/// depending on which of them drew it would be three faces.
enum NoticeFace {
    static func tint(_ tone: NoticePresentation.Tone) -> UIColor {
        switch tone {
        case .live: return .systemGreen
        case .attention: return .systemOrange
        case .danger: return .systemRed
        case .quiet: return .systemGray
        }
    }

    /// The face at `side` points, opaque so it reads on both a light and a dark lock screen.
    static func image(for presentation: NoticePresentation, side: CGFloat = 256) -> UIImage {
        let size = CGSize(width: side, height: side)
        let tint = tint(presentation.tone)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: side * 0.02, dy: side * 0.02)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.225)
            context.cgContext.saveGState()
            path.addClip()
            let colors = [Self.lighter(tint).cgColor, tint.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                context.cgContext.drawLinearGradient(
                    gradient, start: CGPoint(x: 0, y: rect.minY),
                    end: CGPoint(x: 0, y: rect.maxY), options: [])
            }
            context.cgContext.restoreGState()
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.46, weight: .bold)
            guard
                let symbol = UIImage(systemName: presentation.symbol, withConfiguration: config)?
                    .withTintColor(UIColor(white: 0.04, alpha: 0.86), renderingMode: .alwaysOriginal)
            else { return }
            let target = CGRect(
                x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: target)
        }
    }

    /// Written fresh per notification, because the system takes ownership of the file it is handed.
    static func attachment(for presentation: NoticePresentation) -> UNNotificationAttachment? {
        guard let data = image(for: presentation).pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notice-face-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "face", url: url)
        } catch {
            return nil
        }
    }

    /// What a turn drew, as a square with the face in its corner, so a notice about a picture shows
    /// the picture and still says what kind of notice it is.
    static func attachment(picture: Data, presentation: NoticePresentation) -> UNNotificationAttachment? {
        guard let source = UIImage(data: picture), source.size.width > 0, source.size.height > 0
        else { return attachment(for: presentation) }
        let side: CGFloat = 256
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let composed = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let frame = CGRect(origin: .zero, size: size)
            context.cgContext.saveGState()
            UIBezierPath(roundedRect: frame, cornerRadius: side * 0.225).addClip()
            let scale = max(side / source.size.width, side / source.size.height)
            let drawn = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(
                in: CGRect(
                    x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                    width: drawn.width, height: drawn.height))
            context.cgContext.restoreGState()
            let badge = side * 0.42
            let origin = CGPoint(x: side - badge - side * 0.04, y: side - badge - side * 0.04)
            let ring = CGRect(origin: origin, size: CGSize(width: badge, height: badge))
                .insetBy(dx: -side * 0.025, dy: -side * 0.025)
            UIColor(white: 0.08, alpha: 1).setFill()
            UIBezierPath(ovalIn: ring).fill()
            image(for: presentation, side: badge * 2).draw(
                in: CGRect(origin: origin, size: CGSize(width: badge, height: badge)))
        }
        guard let data = composed.pngData() else { return attachment(for: presentation) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notice-picture-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "picture", url: url)
        } catch {
            return attachment(for: presentation)
        }
    }

    private static func lighter(_ color: UIColor) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        else { return color }
        return UIColor(
            hue: hue, saturation: max(0, saturation - 0.28), brightness: min(1, brightness + 0.1),
            alpha: alpha)
    }
}
