import Foundation

/// A value the inspector reports without saying which kind: a number, a pair of numbers, a word.
/// Findings carry what was measured and what was required, and each check measures something
/// different, so the reading keeps them as they came and says them as words.
public enum InspectLoose: Decodable, Sendable, Equatable {
    case number(Double)
    case text(String)
    case flag(Bool)
    case list([InspectLoose])
    case none

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let value = try? container.decode([InspectLoose].self) {
            self = .list(value)
        } else {
            self = .none
        }
    }

    public var words: String {
        switch self {
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        case .text(let value): return value
        case .flag(let value): return value ? "yes" : "no"
        case .list(let values): return values.map(\.words).joined(separator: " × ")
        case .none: return ""
        }
    }
}

public struct InspectNode: Decodable, Sendable, Equatable, Identifiable {
    public struct Accessibility: Decodable, Sendable, Equatable {
        public var label: String?
        public var identifier: String?
        public var hint: String?
        public var value: String?
        public var traits: [String]?
        public var isElement: Bool?
    }

    public struct Font: Decodable, Sendable, Equatable {
        public var name: String
        public var size: Double
    }

    public var id: String
    public var className: String
    public var frame: [Double]
    public var hidden: Bool?
    public var alpha: Double?
    public var interactive: Bool?
    public var text: String?
    public var placeholder: String?
    public var accessibility: Accessibility?
    public var background: String?
    public var textColor: String?
    public var font: Font?
    public var controlTargets: [String]?
    public var children: [InspectNode]?
    public var truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case id, frame, hidden, alpha, interactive, text, placeholder, accessibility, background, textColor, font
        case controlTargets, children, truncated
        case className = "class"
    }

    public var x: Double { frame.count > 0 ? frame[0] : 0 }
    public var y: Double { frame.count > 1 ? frame[1] : 0 }
    public var width: Double { frame.count > 2 ? frame[2] : 0 }
    public var height: Double { frame.count > 3 ? frame[3] : 0 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + width && py >= y && py <= y + height
    }
}

public struct InspectTree: Decodable, Sendable, Equatable {
    public var root: InspectNode
    public var nodeCount: Int
    public var depth: Int
    public var truncated: Bool
}

public struct InspectHello: Decodable, Sendable, Equatable {
    public struct Size: Decodable, Sendable, Equatable {
        public var width: Double
        public var height: Double
    }

    public var app: String
    public var bundleId: String?
    public var window: Size
    public var scale: Double
    public var userInterfaceStyle: String?
    public var preferredContentSizeCategory: String?
}

public struct InspectFinding: Decodable, Sendable, Equatable, Identifiable {
    public var kind: String
    public var severity: String
    public var nodeId: String?
    public var className: String?
    public var text: String?
    public var message: String
    public var measured: InspectLoose?
    public var required: InspectLoose?

    enum CodingKeys: String, CodingKey {
        case kind, severity, nodeId, text, message, measured, required
        case className = "class"
    }

    public var id: String { "\(kind)|\(nodeId ?? "")|\(message)" }
}

public struct InspectAudit: Decodable, Sendable, Equatable {
    public var findings: [InspectFinding]
    public var trustedSystemColors: Int?
}

public struct InspectHit: Decodable, Sendable, Equatable {
    public var path: [String]
    public var node: InspectNode?
}

/// What the screen's own views say about it, read the way a person points at it: where a press
/// lands, what the thing under it is called and what a request about it should carry.
public enum PreviewInspectReading {
    /// The picture's pixels to the screen's points: the host draws the screen at some scale, and
    /// the inspector speaks in points.
    public static func points(pixelX: Double, pixelY: Double, pictureWidth: Double, hello: InspectHello) -> (x: Double, y: Double) {
        let ratio = hello.window.width / max(1, pictureWidth)
        return (pixelX * ratio, pixelY * ratio)
    }

    /// The deepest view that holds a point, found in the tree already read so a press costs no
    /// round trip. Hidden and see-through views are skipped, as UIKit's own hit test skips them, and
    /// so is a container that holds nothing a person can see or press at that point: UIKit lays a
    /// transparent layer over a whole screen for its bars and touch plumbing, and a pointer would
    /// otherwise land on that layer instead of the button underneath it. A control is a leaf: the
    /// label inside a button is a part of the button, and it is the button that is meant.
    public static func chain(in tree: InspectTree, x: Double, y: Double) -> [InspectNode] {
        func holds(_ node: InspectNode) -> Bool {
            node.hidden != true && (node.alpha ?? 1) >= 0.01 && node.contains(x: x, y: y)
        }
        func descend(_ node: InspectNode) -> [InspectNode]? {
            if node.controlTargets != nil { return [node] }
            let inside = (node.children ?? []).reversed().filter(holds)
            let ordered = inside.filter { $0.interactive != false } + inside.filter { $0.interactive == false }
            for child in ordered {
                if let found = descend(child) { return [node] + found }
            }
            return showsSomething(node) ? [node] : nil
        }
        return descend(tree.root) ?? [tree.root]
    }

    /// Whether a view is anything in itself: it carries words, is spoken, answers a press or is
    /// painted a colour that can be seen.
    static func showsSomething(_ node: InspectNode) -> Bool {
        if let text = node.text, !text.isEmpty { return true }
        if let text = node.placeholder, !text.isEmpty { return true }
        if let label = node.accessibility?.label, !label.isEmpty { return true }
        if node.accessibility?.isElement == true { return true }
        if let targets = node.controlTargets, !targets.isEmpty { return true }
        guard let fill = node.background else { return false }
        let digits = fill.drop { $0 == "#" }
        return !(digits.count == 8 && digits.hasSuffix("00"))
    }

    public static func kindWords(_ className: String) -> String {
        let name = className.lowercased()
        if name.contains("button") { return Localized.text("a button") }
        if name.contains("textfield") { return Localized.text("a text field") }
        if name.contains("label") { return Localized.text("some text") }
        if name.contains("imageview") { return Localized.text("a picture") }
        if name.contains("tableview") || name.contains("collectionview") { return Localized.text("a list") }
        if name.contains("scrollview") { return Localized.text("a scrolling area") }
        if name.contains("switch") { return Localized.text("a switch") }
        return Localized.text("a view")
    }

    public static func sizeWords(_ node: InspectNode) -> String {
        "\(Int(node.width.rounded())) × \(Int(node.height.rounded()))"
    }

    public struct Row: Sendable, Equatable {
        public var label: String
        public var value: String
    }

    public static func rows(for node: InspectNode) -> [Row] {
        var rows = [
            Row(label: Localized.text("Position"), value: "\(Int(node.x.rounded())), \(Int(node.y.rounded()))"),
            Row(label: Localized.text("Size"), value: sizeWords(node)),
        ]
        if let text = node.text, !text.isEmpty { rows.append(Row(label: Localized.text("Text"), value: text)) }
        if let background = node.background { rows.append(Row(label: Localized.text("Fill"), value: background.uppercased())) }
        if let font = node.font {
            rows.append(Row(label: Localized.text("Type"), value: "\(font.name) \(Int(font.size.rounded()))"))
        }
        if let label = node.accessibility?.label, !label.isEmpty {
            rows.append(Row(label: Localized.text("Spoken as"), value: "“\(label)”"))
        }
        if let action = node.controlTargets?.first {
            rows.append(Row(label: Localized.text("When pressed"), value: action))
        }
        return rows
    }

    /// The sentence that goes in front of a person's request when they point at a view, so an agent
    /// that was not looking knows exactly which view is meant.
    public static func context(for node: InspectNode, app: String) -> String {
        let name = node.text.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? node.accessibility?.label.map { "“\($0)”" } ?? node.className
        return Localized.text(
            "In the preview of %@, I am pointing at %@ — %@, class %@, %@ points, at %@.", app, kindWords(node.className),
            name, node.className, sizeWords(node), "\(Int(node.x.rounded())), \(Int(node.y.rounded()))")
    }

    public struct FindingWords: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var fails: Bool
    }

    public static func words(for finding: InspectFinding) -> FindingWords {
        let fails = finding.severity == "fail"
        let measured = finding.measured?.words ?? ""
        let required = finding.required?.words ?? ""
        switch finding.kind {
        case "contrast":
            return FindingWords(
                title: Localized.text("Hard to read"),
                detail: Localized.text("The text is %@ to 1 against its background. It needs %@ to 1.", measured, required),
                fails: fails)
        case "tapTarget":
            return FindingWords(
                title: Localized.text("Hard to press"),
                detail: Localized.text("This is %@. A finger needs at least %@.", measured, required), fails: fails)
        case "truncation":
            return FindingWords(
                title: Localized.text("Words cut off"),
                detail: Localized.text("“%@” does not fit its space.", finding.text ?? finding.className ?? ""), fails: fails)
        case "missingLabel":
            return FindingWords(
                title: Localized.text("Not spoken"),
                detail: Localized.text("%@ has no description, so VoiceOver skips it.", finding.className ?? Localized.text("A view")),
                fails: fails)
        default:
            return FindingWords(title: finding.kind, detail: finding.message, fails: fails)
        }
    }

    public struct Place: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    /// Where a view stands on the picture, as fractions of the picture's own width and height. The
    /// picture is the whole window, so a fraction is the same at any size the picture is drawn, and
    /// whatever lays an outline over it multiplies by the size it has drawn the picture at.
    public static func place(of node: InspectNode, in hello: InspectHello) -> Place {
        let width = max(1, hello.window.width)
        let height = max(1, hello.window.height)
        let left = min(1, max(0, node.x / width))
        let top = min(1, max(0, node.y / height))
        let right = min(1, max(0, (node.x + node.width) / width))
        let bottom = min(1, max(0, (node.y + node.height) / height))
        return Place(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    /// A press at a fraction of the picture, in the screen's points.
    public static func points(fractionX: Double, fractionY: Double, hello: InspectHello) -> (x: Double, y: Double) {
        (fractionX * hello.window.width, fractionY * hello.window.height)
    }

    /// The view a press at a fraction of the picture lands on and the views it sits in, outermost
    /// first. The window itself is not a view anybody points at, so it leads the chain only as the
    /// parent a breadcrumb walks up to.
    public static func chain(in tree: InspectTree, hello: InspectHello, fractionX: Double, fractionY: Double) -> [InspectNode] {
        let point = points(fractionX: fractionX, fractionY: fractionY, hello: hello)
        return chain(in: tree, x: point.x, y: point.y)
    }

    /// The views from the window down to the one with this id, or nothing when the screen has
    /// changed since and no longer holds it.
    public static func path(to nodeID: String, in tree: InspectTree) -> [InspectNode] {
        func walk(_ node: InspectNode, _ trail: [InspectNode]) -> [InspectNode]? {
            let here = trail + [node]
            if node.id == nodeID { return here }
            for child in node.children ?? [] {
                if let found = walk(child, here) { return found }
            }
            return nil
        }
        return walk(tree.root, []) ?? []
    }

    /// What a person would call the view: the words on it, what it is spoken as, or its kind.
    public static func name(of node: InspectNode) -> String {
        if let text = node.text, !text.isEmpty { return "“\(text)”" }
        if let label = node.accessibility?.label, !label.isEmpty { return "“\(label)”" }
        return shortClass(node.className)
    }

    /// The class without its module or its UIKit prefix, and cut where one of UIKit's own mangled
    /// private names would run on for sixty characters.
    public static func shortClass(_ className: String) -> String {
        let bare = className.split(separator: ".").last.map(String.init) ?? className
        let plain = bare.hasPrefix("UI") && bare.count > 2 ? String(bare.dropFirst(2)) : bare
        return plain.count > 28 ? String(plain.prefix(27)) + "…" : plain
    }

    /// One line a breadcrumb or a finding can wear to say where a view is.
    public static func crumb(_ node: InspectNode) -> String {
        let kind = shortClass(node.className)
        guard let text = node.text, !text.isEmpty else { return kind }
        let shown = text.count > 18 ? String(text.prefix(17)) + "…" : text
        return "\(kind) “\(shown)”"
    }

    /// The request that hands every finding of an audit to the agent, each with the view it is
    /// about, so the agent is asked to fix exactly what the checks found and nothing it guessed.
    public static func fixRequest(findings: [InspectFinding], tree: InspectTree?, app: String) -> String {
        let lines = findings.map { finding -> String in
            let words = Self.words(for: finding)
            let view = tree.flatMap { path(to: finding.nodeId ?? "", in: $0).last }.map(name(of:))
                ?? finding.text.map { "“\($0)”" } ?? finding.className ?? ""
            return "- \(words.title): \(view). \(words.detail)"
        }
        return Localized.text(
            "The preview of %@ was checked and %@ need attention:\n%@\nPlease fix them in the code.", app,
            String(findings.count), lines.joined(separator: "\n"))
    }

    /// What to say beside a finding about the view it is about, so two of one kind can be told apart.
    public static func subject(of finding: InspectFinding, in tree: InspectTree?) -> String {
        if let node = tree.flatMap({ path(to: finding.nodeId ?? "", in: $0).last }) { return crumb(node) }
        if let text = finding.text, !text.isEmpty { return "“\(text)”" }
        return finding.className.map(shortClass) ?? ""
    }

    public static func summary(_ audit: InspectAudit) -> String {
        audit.findings.isEmpty
            ? Localized.text("Nothing needs attention on this screen")
            : Localized.text("%@ need attention", String(audit.findings.count))
    }
}
