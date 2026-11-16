import Foundation

/// What a picture in the transcript can be asked to do where it stands, named once.
///
/// Copying or saving a picture used to mean opening the viewer on the desktops, and on the phone a
/// strip of pictures answered a long press with the row's menu, whose Copy copied filenames. A
/// lone picture and every tile of a strip now answer alike, and a client offers the verbs its
/// platform has in the order given here.
public enum PictureVerb: String, Sendable, CaseIterable {
    case open
    case copy
    case saveToDownloads
    case saveToPhotos
    case saveToFiles
    case share
    case copyPath

    public var title: String {
        switch self {
        case .open: return Localized.text("Open")
        case .copy: return Localized.text("Copy image")
        case .saveToDownloads: return Localized.text("Save to Downloads")
        case .saveToPhotos: return Localized.text("Save to Photos")
        case .saveToFiles: return Localized.text("Save to Files")
        case .share: return Localized.text("Share")
        case .copyPath: return Localized.text("Copy path")
        }
    }

    /// The symbol a client with SF Symbols draws beside the verb.
    public var symbol: String {
        switch self {
        case .open: return "arrow.up.left.and.arrow.down.right"
        case .copy: return "doc.on.doc"
        case .saveToDownloads: return "arrow.down.to.line"
        case .saveToPhotos: return "square.and.arrow.down"
        case .saveToFiles: return "folder"
        case .share: return "square.and.arrow.up"
        case .copyPath: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

public enum PictureVerbs {
    /// A desktop's menu on a picture: open it, take it, keep it, and the path an agent knows it by
    /// when the picture has one.
    public static func pointer(hasPath: Bool) -> [PictureVerb] {
        [.open, .copy, .saveToDownloads] + (hasPath ? [.copyPath] : [])
    }

    /// The phone's menu on a picture, which a tap already opens.
    public static let touch: [PictureVerb] = [.saveToPhotos, .copy, .saveToFiles, .share]
}
