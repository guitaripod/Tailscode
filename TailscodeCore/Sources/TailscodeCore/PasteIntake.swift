import Foundation

/// What the clipboard is holding, as the platform found it. Every desktop and the phone report the
/// same three things in the same order of preference, so what a paste *means* is decided once here
/// rather than three times in three toolkits.
public struct ClipboardOffer: Sendable {
    public var paths: [String]
    public var image: Data?
    public var imageMime: String
    public var text: String?

    public init(
        paths: [String] = [], image: Data? = nil, imageMime: String = "image/png",
        text: String? = nil
    ) {
        self.paths = paths
        self.image = image
        self.imageMime = imageMime
        self.text = text
    }

    public var isEmpty: Bool {
        paths.isEmpty && image == nil && (text ?? "").isEmpty
    }
}

/// What one paste turns into.
public struct PastePlan: Sendable {
    /// Chips to add, in the order they were on the clipboard.
    public let attachments: [PendingAttachment]
    /// Words to insert at the caret. Nil when the paste was not words.
    public let text: String?
    /// What could not be taken, said out loud. A paste that silently dropped half of what was on
    /// the clipboard is worse than one that refused it.
    public let notices: [String]
    /// How many things this plan named, so the next paste in the same composer does not reuse a
    /// filename.
    public let named: Int

    public var isEmpty: Bool { attachments.isEmpty && (text ?? "").isEmpty }
}

/// A paste is an attach as much as it is a paste.
///
/// What is on the clipboard is almost never ambiguous — a file manager offers paths, a screenshot
/// tool offers pixels, everything else offers words — so the composer takes whichever it is rather
/// than making a person save a picture to disk and pick it back up through a file chooser. Only
/// words go in as words, and even then a paste the size of a document is the document it already
/// is: it becomes a file, because thousands of lines wedged into a prompt box is a thing nobody can
/// read, edit or take back out.
public enum PasteIntake {
    /// Past this a paste has stopped being a sentence. Deliberately far above anything a person
    /// types or quotes by hand — a stack trace, a diff, a page of log all still land as words,
    /// because turning ordinary pasted text into an attachment would be a surprise every time.
    public static let inlineCharacterLimit = 20_000
    public static let inlineLineLimit = 400

    public static func plan(
        for offer: ClipboardOffer, abilities: ModelAbilities, alreadyNamed: Int = 0
    ) -> PastePlan {
        var attachments: [PendingAttachment] = []
        var notices: [String] = []
        var named = alreadyNamed

        if !offer.paths.isEmpty {
            guard abilities.attachments else {
                return PastePlan(
                    attachments: [], text: nil,
                    notices: [Localized.text("This model can't be handed files.")], named: named)
            }
            for path in offer.paths {
                switch AttachmentIntake.read(path: path) {
                case .success(let attachment):
                    guard abilities.accepts(mime: attachment.mime) else {
                        notices.append(
                            Localized.text("This model can't read %@", attachment.name))
                        continue
                    }
                    attachments.append(attachment)
                case .failure(let refusal):
                    notices.append(refusal.message)
                }
            }
            return PastePlan(
                attachments: attachments, text: nil, notices: notices, named: named)
        }

        if let image = offer.image {
            guard abilities.vision else {
                return PastePlan(
                    attachments: [], text: nil,
                    notices: [Localized.text("This model can't read pictures.")], named: named)
            }
            guard image.count <= AttachmentIntake.byteCap else {
                return PastePlan(
                    attachments: [], text: nil,
                    notices: [
                        Localized.text(
                            "That picture is %@ — the cap is 8 MB",
                            AttachmentIntake.sizeText(image.count))
                    ], named: named)
            }
            named += 1
            attachments.append(
                PendingAttachment(
                    name: "pasted-\(named).\(Self.extension(forImage: offer.imageMime))",
                    mime: offer.imageMime, data: image))
            return PastePlan(attachments: attachments, text: nil, notices: [], named: named)
        }

        guard let text = offer.text, !text.isEmpty else {
            return PastePlan(attachments: [], text: nil, notices: [], named: named)
        }
        let lines = text.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
        let overlong = text.count > inlineCharacterLimit || lines > inlineLineLimit
        guard overlong, abilities.attachments else {
            return PastePlan(attachments: [], text: text, notices: [], named: named)
        }
        named += 1
        let name = "pasted-\(named).txt"
        return PastePlan(
            attachments: [
                PendingAttachment(name: name, mime: "text/plain", data: Data(text.utf8))
            ], text: nil,
            notices: [
                Localized.text(
                    "%@ lines came in as %@ rather than into the box", "\(lines)", name)
            ], named: named)
    }

    private static func `extension`(forImage mime: String) -> String {
        switch mime {
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "png"
        }
    }
}
