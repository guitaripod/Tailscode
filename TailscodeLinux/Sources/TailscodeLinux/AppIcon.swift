import CGtkShim
import Foundation

/// The symbolic glyphs Settings wears, drawn here so they look the same under every icon theme.
/// A theme is the person's choice and no two agree on which names they carry — Adwaita has
/// `chat-message-new-symbolic` and Breeze does not, Breeze has `notifications-symbolic` and Adwaita
/// does not — and GTK answers a name its theme lacks with a red prohibition sign. Each glyph is a
/// 16×16 filled shape, which is all GTK's symbolic loader recolours, written once into the app's own
/// data directory and put on the icon theme's search path.
enum AppIcon: String, CaseIterable {
    case general = "tailscode-general-symbolic"
    case appearance = "tailscode-appearance-symbolic"
    case conversation = "tailscode-conversation-symbolic"
    case notifications = "tailscode-notifications-symbolic"
    case accounts = "tailscode-accounts-symbolic"
    case keyboard = "tailscode-keyboard-symbolic"
    case advanced = "tailscode-advanced-symbolic"
    case warning = "tailscode-warning-symbolic"

    /// The name to hand GTK. Reading it is what puts the glyphs on disk and on the search path, so a
    /// name is never offered before its file exists.
    var name: String {
        Self.installed
        return rawValue
    }

    private static let installed: Void = {
        let directory = directoryURL.appendingPathComponent("hicolor/scalable/actions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for icon in allCases {
            let target = directory.appendingPathComponent("\(icon.rawValue).svg")
            let document = icon.document
            guard (try? String(contentsOf: target, encoding: .utf8)) != document else { continue }
            try? document.write(to: target, atomically: true, encoding: .utf8)
        }
        guard let display = gdk_display_get_default() else { return }
        gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(display), directoryURL.path)
    }()

    private static var directoryURL: URL {
        let dataHome =
            ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        return URL(fileURLWithPath: dataHome, isDirectory: true)
            .appendingPathComponent("tailscode/icons", isDirectory: true)
    }

    private var document: String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">\(shapes)</svg>
        """
    }

    private var shapes: String {
        switch self {
        case .general:
            return """
                <g transform="translate(8 8)"><path fill-rule="evenodd" d="M0-5.4A5.4 5.4 0 1 1 0 5.4A5.4 5.4 0 1 1 0-5.4ZM0-2.3A2.3 2.3 0 1 0 0 2.3A2.3 2.3 0 1 0 0-2.3Z"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(45)"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(90)"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(135)"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(180)"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(225)"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(270)"/>\
                <rect x="-1.4" y="-7.4" width="2.8" height="3.2" transform="rotate(315)"/></g>
                """
        case .appearance:
            return """
                <path fill-rule="evenodd" d="M8 1.2A6.8 6.8 0 1 1 8 14.8A6.8 6.8 0 1 1 8 1.2ZM8 2.7A5.3 5.3 0 1 0 8 13.3A5.3 5.3 0 1 0 8 2.7Z"/>\
                <path d="M8 4.1A3.9 3.9 0 0 1 8 11.9Z"/>
                """
        case .conversation:
            return """
                <path fill-rule="evenodd" d="M3.5 1.8h9A1.7 1.7 0 0 1 14.2 3.5v6A1.7 1.7 0 0 1 12.5 11.2H8.4L5 14.4V11.2H3.5A1.7 1.7 0 0 1 1.8 9.5v-6A1.7 1.7 0 0 1 3.5 1.8ZM4.6 4.4v1.3h6.8V4.4ZM4.6 7v1.3h4.4V7Z"/>
                """
        case .notifications:
            return """
                <path d="M8 1.2a1 1 0 0 1 1 1v.5c1.9.5 3.1 2.2 3.1 4.2v2.4l1.4 1.8v1H2.5v-1L3.9 9.3V6.9c0-2 1.2-3.7 3.1-4.2v-.5a1 1 0 0 1 1-1Z"/>\
                <path d="M6.1 13.4h3.8a1.9 1.9 0 0 1-3.8 0Z"/>
                """
        case .accounts:
            return """
                <circle cx="8" cy="4.9" r="3"/>\
                <path d="M2.6 14.4c0-3.1 2.4-5 5.4-5s5.4 1.9 5.4 5Z"/>
                """
        case .keyboard:
            return """
                <path fill-rule="evenodd" d="M2.5 3.2h11A1.5 1.5 0 0 1 15 4.7v6.6a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 11.3V4.7a1.5 1.5 0 0 1 1.5-1.5ZM3 5.2v1.4h1.6V5.2ZM5.8 5.2v1.4h1.6V5.2ZM8.6 5.2v1.4h1.6V5.2ZM11.4 5.2v1.4H13V5.2ZM3 7.6V9h1.6V7.6ZM5.8 7.6V9h4.4V7.6ZM11.4 7.6V9H13V7.6ZM4.6 10v1.2h6.8V10Z"/>
                """
        case .advanced:
            return """
                <rect x="1.5" y="3.2" width="13" height="1.6" rx=".8"/>\
                <rect x="1.5" y="7.2" width="13" height="1.6" rx=".8"/>\
                <rect x="1.5" y="11.2" width="13" height="1.6" rx=".8"/>\
                <circle cx="10.6" cy="4" r="2.1"/><circle cx="5.2" cy="8" r="2.1"/><circle cx="9.6" cy="12" r="2.1"/>
                """
        case .warning:
            return """
                <path fill-rule="evenodd" d="M8 1.6c.4 0 .8.2 1 .6l5.7 9.9c.4.7-.1 1.6-.9 1.6H2.2c-.8 0-1.3-.9-.9-1.6L7 2.2c.2-.4.6-.6 1-.6ZM7.3 5.4v3.9h1.4V5.4ZM7.3 10.3v1.4h1.4v-1.4Z"/>
                """
        }
    }
}
