import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The picture a desktop notification can actually show. GNotification stops at a themed icon;
/// this paints the face the chat's badge raises — and, when the turn handed a picture back and
/// this device already has the bytes, that picture with the face in the corner — and writes it
/// where the notification daemon can read it.
enum NotificationPlate {
    static func kindWord(_ reason: ActivityAlert.Reason) -> String {
        switch reason {
        case .turnEnded: return Localized.text("finished")
        case .turnFailed: return Localized.text("failed")
        case .needsApproval: return Localized.text("needs approval")
        case .needsAnswer: return Localized.text("has a question")
        }
    }

    static func kindWord(_ kind: DelegateNotice.Kind) -> String {
        switch kind {
        case .asks: return Localized.text("needs approval")
        case .passed: return Localized.text("finished")
        case .failed: return Localized.text("failed")
        }
    }

    static func sound(_ reason: ActivityAlert.Reason) -> String {
        switch reason {
        case .turnEnded: return "complete"
        case .turnFailed: return "dialog-warning"
        case .needsApproval, .needsAnswer: return "message-new-instant"
        }
    }

    static func sound(_ kind: DelegateNotice.Kind) -> String {
        switch kind {
        case .asks: return "message-new-instant"
        case .passed: return "complete"
        case .failed: return "dialog-warning"
        }
    }

    static func category(_ reason: ActivityAlert.Reason) -> String {
        switch reason {
        case .turnEnded: return "transfer.complete"
        case .turnFailed: return "device.error"
        case .needsApproval, .needsAnswer: return "im.received"
        }
    }

    static func category(_ kind: DelegateNotice.Kind) -> String {
        switch kind {
        case .asks: return "im.received"
        case .passed: return "transfer.complete"
        case .failed: return "device.error"
        }
    }

    /// The body as a daemon that reads markup must be given it — an agent's question is free text,
    /// and a `<` or `&` in it would otherwise be eaten as a tag — and as one that does not wants it.
    static func wording(body: String) -> (markup: String, plain: String) {
        (escape(body), body)
    }

    /// The newest picture this device has already fetched for the turn that just ended, never an
    /// earlier turn's and never one the person attached themselves: a notice that shows last
    /// hour's screenshot for a turn that drew nothing is a wrong answer. A notice must not wait on
    /// the tailnet, so a picture that is not on disk yet is simply not in the notice.
    static func cachedPicture(in state: ConversationState) -> Data? {
        for message in state.messages.reversed() {
            if message.role == .user { return nil }
            for part in message.parts.reversed() {
                guard case .file(let reference) = part.kind, isImage(reference),
                    let data = ImageCache.load(reference), data.count > 32, data.count < 8_000_000
                else { continue }
                return data
            }
        }
        return nil
    }

    static func imagePath(
        face: AlertFace, caption: String, picture: Data?, name: String
    ) -> String? {
        guard let png = render(face: face, caption: picture == nil ? caption : nil, picture: picture)
        else { return nil }
        let directory = cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(sanitize(name) + ".png")
        do {
            try png.write(to: file, options: .atomic)
            prune(directory)
            return file.path
        } catch {
            return nil
        }
    }

    /// The same face, small, for the missed-notice row. Without its word, which at this size is a
    /// smear. Cached by the colours it was painted in, so a theme change paints a new one and a
    /// sidebar rebuild does not.
    static func badge(face: AlertFace, side: Int32) -> UnsafeMutablePointer<GtkWidget>? {
        let palette = MatrixTheme.palette
        let key = "\(face.glyph)|\(toneHex(face.tone, palette))|\(palette.onAccent)"
        let texture: OpaquePointer
        if let cached = textures[key] {
            texture = cached
        } else {
            guard
                let png = render(face: face, caption: nil, picture: nil),
                let made = png.withUnsafeBytes({
                    tailscode_texture_from_bytes($0.baseAddress, gsize($0.count))
                })
            else { return nil }
            textures[key] = made
            texture = made
        }
        guard let widget = tailscode_picture_for_texture_sized(texture, side, side) else {
            return nil
        }
        gtk_widget_set_size_request(widget, side, side)
        return widget
    }

    static func render(face: AlertFace, caption: String?, picture: Data?) -> Data? {
        let palette = MatrixTheme.palette
        return render(
            tone: toneHex(face.tone, palette), ink: palette.onAccent, canvas: palette.canvas,
            glyph: face.glyph, caption: caption, picture: picture)
    }

    static func render(
        tone: String, ink: String, canvas: String, glyph: String, caption: String?,
        picture: Data?
    ) -> Data? {
        var length: gsize = 0
        let raw: UnsafeMutablePointer<UInt8>?
        if let picture, !picture.isEmpty {
            raw = picture.withUnsafeBytes { buffer in
                tailscode_notification_plate_png(
                    tone, ink, canvas, glyph, caption, buffer.baseAddress, gsize(buffer.count),
                    &length)
            }
        } else {
            raw = tailscode_notification_plate_png(
                tone, ink, canvas, glyph, caption, nil, 0, &length)
        }
        guard let raw, length > 0 else { return nil }
        defer { g_free(raw) }
        return Data(bytes: raw, count: Int(length))
    }

    nonisolated(unsafe) private static var textures: [String: OpaquePointer] = [:]
    nonisolated(unsafe) private static var serial = 0

    static func nextName(_ identifier: String) -> String {
        serial += 1
        return "\(identifier)-\(serial)"
    }

    private static var cacheDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("tailscode/notices", isDirectory: true)
    }

    private static func toneHex(_ tone: ActivityTone, _ palette: Palette) -> String {
        switch tone {
        case .live: return palette.accent
        case .attention: return palette.warn
        case .danger: return palette.danger
        case .quiet: return palette.textDim
        }
    }

    private static func isImage(_ reference: FileReference) -> Bool {
        if let mime = reference.mime, mime.hasPrefix("image/") { return true }
        let name = (reference.filename ?? reference.path ?? "").lowercased()
        return [".png", ".jpg", ".jpeg", ".webp", ".gif"].contains { name.hasSuffix($0) }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let text = String(cleaned)
        return text.isEmpty ? "notice" : String(text.prefix(80))
    }

    private static func prune(_ directory: URL) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles), files.count > 32
        else { return }
        let dated = files.map { file in
            (
                file,
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            )
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - 32) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

func notificationCStrings<R>(
    _ values: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R
) -> R {
    let copies = values.map { strdup($0) }
    defer { for copy in copies { free(copy) } }
    let pointers: [UnsafePointer<CChar>?] = copies.map { UnsafePointer($0) }
    return pointers.withUnsafeBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
