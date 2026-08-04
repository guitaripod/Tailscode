import Foundation

/// What a browser slot is pointed at. Typed the way people type addresses — a bare host, a port on
/// this machine, a path, or words to look up — because a pane that only accepts perfect URLs makes
/// its owner do the browser's job.
public enum WebTarget: Sendable, Equatable, Hashable, Codable {
    case page(String)
    case search(String)

    public static func classify(_ input: String) -> WebTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("file://") {
            return .page(text)
        }
        if let port = localPort(text) { return .page(port) }
        if text.hasPrefix("/") || text.hasPrefix("~") { return .page("file://\(expand(text))") }
        if isHost(text) { return .page("https://\(text)") }
        return .search(text)
    }

    /// What the pane actually opens.
    public var url: String {
        switch self {
        case .page(let url): return url
        case .search(let words): return "https://duckduckgo.com/?q=\(Self.encode(words))"
        }
    }

    /// What a layout snapshot keeps. A slot restores the page it ended on, so what is persisted is
    /// always a real address — a search that has already been run is the page it produced.
    public var address: String { url }

    public var label: String {
        switch self {
        case .page(let url): return Self.shortened(url)
        case .search(let words): return words
        }
    }

    private static func localPort(_ text: String) -> String? {
        if text.hasPrefix(":"), let port = Int(text.dropFirst().prefix(while: \.isNumber)),
            port > 0, port < 65536
        {
            let rest = text.dropFirst().drop(while: \.isNumber)
            return "http://localhost:\(port)\(rest)"
        }
        let hosts = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"]
        for host in hosts where text == host || text.hasPrefix("\(host):") || text.hasPrefix("\(host)/") {
            return "http://\(text)"
        }
        return nil
    }

    private static func isHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        let tail = host.split(separator: ".").last.map(String.init) ?? ""
        return tail.count >= 2 && tail.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func expand(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSString(string: path).expandingTildeInPath
    }

    private static func encode(_ words: String) -> String {
        words.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? words
    }

    private static func shortened(_ url: String) -> String {
        let stripped = url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        return stripped.count > 48 ? String(stripped.prefix(47)) + "…" : stripped
    }
}

public enum WebSlotPhase: Sendable, Equatable {
    case asking
    case loading(Double)
    case showing
    case failed(String)
}

/// The browser slot's model, toolkit-free: what it points at, what it is doing, and every word the
/// two desktops draw around it. The engine differs per platform — WebKitGTK on one, WKWebView on
/// the other — but the pane behaves identically, which is what parity judges.
public struct WebSlot: Sendable, Equatable {
    public private(set) var target: WebTarget?
    public private(set) var phase: WebSlotPhase
    public private(set) var pageTitle: String?
    public private(set) var currentURL: String?
    public var draft: String
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var zoom: Double

    public init(target: WebTarget? = nil) {
        self.target = target
        phase = target == nil ? .asking : .loading(0)
        draft = ""
        canGoBack = false
        canGoForward = false
        zoom = 1
    }

    public mutating func point(at target: WebTarget) {
        self.target = target
        phase = .loading(0)
        pageTitle = nil
        currentURL = target.url
        draft = ""
    }

    public mutating func progress(_ fraction: Double) {
        guard case .failed = phase else {
            phase = fraction >= 1 ? .showing : .loading(max(0, min(1, fraction)))
            return
        }
    }

    public mutating func arrived(url: String?, title: String?) {
        if let url, !url.isEmpty { currentURL = url }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        pageTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        phase = .showing
    }

    public mutating func failed(_ reason: String) {
        phase = .failed(reason)
    }

    /// Back to the address bar with what it is showing already in it, so a typo is an edit.
    public mutating func ask() {
        draft = currentURL ?? target?.label ?? draft
        phase = .asking
    }

    public var isAsking: Bool { phase == .asking }

    /// What the identity strip says: the page's own title once it has one, its address until then.
    public var title: String {
        if let pageTitle { return pageTitle }
        if let currentURL { return WebTarget.page(currentURL).label }
        if let target { return target.label }
        return Localized.text("Browse")
    }

    public var subtitle: String {
        switch phase {
        case .asking: return Localized.text("Nothing open")
        case .loading(let fraction):
            return Localized.text("Loading %@%%", "\(Int(fraction * 100))")
        case .showing:
            guard let currentURL else { return "" }
            return WebTarget.page(currentURL).label
        case .failed(let reason): return reason
        }
    }

    public var prompt: String { Localized.text("Address, or words to look up") }

    public var hint: String {
        Localized.text(
            "enter opens · ctrl+l address · alt+←→ history · ctrl+r reloads · ctrl+w c closes")
    }
}

/// What a keystroke means inside a browsing pane. Deliberately narrow: a page takes the keyboard,
/// so only chords a browser owns are claimed here and every plain key goes to the page.
public enum WebCommand: Sendable, Equatable {
    case back
    case forward
    case reload
    case stop
    case address
    case zoomIn
    case zoomOut
    case zoomReset

    public static func command(for chord: KeyChord) -> WebCommand? {
        if chord.alt, !chord.control {
            switch chord.keyval {
            case 0xFF51: return .back
            case 0xFF53: return .forward
            default: return nil
            }
        }
        if chord.control, !chord.alt {
            guard let character = Keymap.scalar(chord.keyval) else { return nil }
            switch character {
            case "r": return .reload
            case "l": return .address
            case "+", "=": return .zoomIn
            case "-": return .zoomOut
            case "0": return .zoomReset
            default: return nil
            }
        }
        guard !chord.control, !chord.alt else { return nil }
        switch chord.keyval {
        case 0xFFC2: return .reload
        case Keymap.escape: return .stop
        default: return nil
        }
    }

    /// The zoom a step lands on, kept here so both desktops step the same amounts and stop at the
    /// same ends rather than each inventing a ladder.
    public static func zoom(_ current: Double, _ command: WebCommand) -> Double {
        switch command {
        case .zoomIn: return min(3.0, (current * 1.1).rounded(toPlaces: 2))
        case .zoomOut: return max(0.4, (current / 1.1).rounded(toPlaces: 2))
        case .zoomReset: return 1
        default: return current
        }
    }
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = Foundation.pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
