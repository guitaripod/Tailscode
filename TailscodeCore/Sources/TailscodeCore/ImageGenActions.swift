import Foundation

/// What a finished picture can be made to do. These are the reason the surface is a place rather
/// than a button: a render that lands and then needs a file manager, a browser and a terminal to
/// be worth anything is a render nobody keeps.
///
/// The order is the order a hand reaches for them — the two that get the picture out of the app
/// first, then the ones that make another, then the one that throws it away.
public enum ImageGenAction: String, Sendable, Equatable, CaseIterable {
    case save
    case share
    case copy
    case open
    case again
    case reference
    case discard
    /// Put the picture on the stage without opening it — a deliberate choice, offered where a
    /// tap opens the picture instead so that tapping never decides what the next render is about.
    case stage

    public var title: String {
        switch self {
        case .save: return Localized.text("Save…")
        case .share: return Localized.text("Share")
        case .copy: return Localized.text("Copy")
        case .open: return Localized.text("Open")
        case .again: return Localized.text("Again")
        case .reference: return Localized.text("Use as reference")
        case .discard: return Localized.text("Discard")
        case .stage: return Localized.text("Show on stage")
        }
    }

    /// The same verb on a phone, where saving means the photo library and the sheet says where
    /// else a picture can go.
    public var phoneTitle: String {
        switch self {
        case .save: return Localized.text("Save")
        case .reference: return Localized.text("Edit this")
        default: return title
        }
    }

    public var symbol: String {
        switch self {
        case .save: return "square.and.arrow.down"
        case .share: return "square.and.arrow.up"
        case .copy: return "doc.on.doc"
        case .open: return "arrow.up.left.and.arrow.down.right"
        case .again: return "arrow.triangle.2.circlepath"
        case .reference: return "photo.badge.plus"
        case .discard: return "trash"
        case .stage: return "rectangle.stack"
        }
    }

    public var glyph: String {
        switch self {
        case .save: return "↓"
        case .share: return "↗"
        case .copy: return "⧉"
        case .open: return "⤢"
        case .again: return "↻"
        case .reference: return "+"
        case .discard: return "✕"
        case .stage: return "◧"
        }
    }

    /// What the control promises before it is pressed, which is the whole difference between a
    /// row of icons and a row of verbs somebody can trust.
    public var hint: String {
        switch self {
        case .save: return Localized.text("Write the picture somewhere of your own")
        case .share: return Localized.text("Hand the picture to another app or person")
        case .copy: return Localized.text("Put the picture on the clipboard")
        case .open: return Localized.text("See it at full size")
        case .again: return Localized.text("Same words, another roll of the dice")
        case .reference: return Localized.text("Start the next render from this picture")
        case .discard: return Localized.text("Let go of this one")
        case .stage: return Localized.text("Put this picture on the stage without opening it")
        }
    }

    /// The one action that destroys something, which a client draws differently and never puts
    /// under a hand reaching for the ones beside it.
    public var isDestructive: Bool { self == .discard }

    /// Everything worth offering for a picture made this session on a desk with no share sheet.
    public static var forPicture: [ImageGenAction] {
        allCases.filter { $0 != .share && $0 != .stage }
    }

    /// What a picture can be made to do, decided by what it is and where it is shown. A picture
    /// the machine keeps has no words to roll again unless its file recorded them, and cannot be
    /// discarded from a folder this app does not own; a phone shares through a sheet and opens by a
    /// tap, so neither is a button in its bar.
    public static func offered(
        kept: Bool, hasWords: Bool, sharing: Bool, tapOpens: Bool
    ) -> [ImageGenAction] {
        var actions: [ImageGenAction] = [.save]
        if sharing { actions.append(.share) }
        actions.append(.copy)
        if !tapOpens { actions.append(.open) }
        if hasWords { actions.append(.again) }
        actions.append(.reference)
        if !kept { actions.append(.discard) }
        return actions
    }
}

/// Where a reference can come from, in the order a hand reaches: the pictures already on the
/// device, the camera, the file system, whatever was last copied, and the machine's own gallery.
/// A client offers the ones its platform has.
public enum ImageGenReferenceSource: String, Sendable, Equatable, CaseIterable {
    case photos
    case camera
    case files
    case clipboard
    case library

    public var title: String {
        switch self {
        case .photos: return Localized.text("Photo Library")
        case .camera: return Localized.text("Take a Photo")
        case .files: return Localized.text("Choose a File")
        case .clipboard: return Localized.text("Paste")
        case .library: return Localized.text("From the Library")
        }
    }

    public var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .camera: return "camera"
        case .files: return "folder"
        case .clipboard: return "doc.on.clipboard"
        case .library: return "photo.stack"
        }
    }
}
