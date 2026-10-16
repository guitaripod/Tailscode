import CodingAgentKit
import Foundation

/// The preview pane's model, toolkit-free: what it is pointed at, what the runner last said, and
/// every word the desktops draw around the picture. The toolkit only decides how a picture is
/// painted, which is what parity judges.
public struct PreviewSlot: Sendable, Equatable {
    public private(set) var target: PreviewTarget?
    public private(set) var state: PreviewState
    public var draft: String
    public var appearance: String

    public init(target: PreviewTarget? = nil) {
        self.target = target
        state = PreviewState()
        draft = ""
        appearance = "light"
    }

    public mutating func point(at target: PreviewTarget) {
        self.target = target
        state = PreviewState()
        draft = ""
    }

    public mutating func apply(_ state: PreviewState) {
        self.state = state
    }

    public mutating func ask() {
        draft = target?.project ?? draft
        target = nil
        state = PreviewState()
    }

    public var isAsking: Bool { target == nil }

    public var light: PreviewLight { target == nil ? .dark : state.light }

    public var title: String {
        guard let target else { return Localized.text("Preview") }
        return target.appName
    }

    public var subtitle: String {
        guard let target else { return Localized.text("Nothing open") }
        return "\(target.host) · \(state.line)"
    }

    public var prompt: String { Localized.text("Folder of the app on the Mac") }

    public var hint: String {
        Localized.text("enter opens · a light or dark · r rebuilds · ctrl+w c closes")
    }

    public var checklist: [PreviewChecklistRow] {
        state.checks.map { check in
            let job = check.fix.flatMap { state.fixes[$0] }
            return PreviewChecklistRow(
                id: check.id, title: PreviewReading.title(of: check), detail: PreviewReading.detail(of: check),
                state: check.state, fix: check.fix, fixLabel: check.fix.map(PreviewReading.fixLabel),
                progress: job?.fraction, working: job?.state == .running)
        }
    }

    /// Asked for a toggle of light and dark: what the Mac's simulator should be set to next.
    public var nextAppearance: String { appearance == "dark" ? "light" : "dark" }
}

/// One line of the checklist a pane draws while a Mac is being set up.
public struct PreviewChecklistRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var state: DoctorCheck.State
    public var fix: String?
    public var fixLabel: String?
    public var progress: Double?
    public var working: Bool
}

/// What a keystroke means inside a preview pane. Narrow on purpose: the picture takes no keys, so
/// only these plain letters are claimed, and only while the pane is focused.
public enum PreviewCommand: Sendable, Equatable {
    case toggleAppearance
    case rebuild
    case copyPicture

    public static func command(for chord: KeyChord) -> PreviewCommand? {
        guard !chord.control, !chord.alt, let character = Keymap.scalar(chord.keyval) else { return nil }
        switch character {
        case "a": return .toggleAppearance
        case "r": return .rebuild
        case "y": return .copyPicture
        default: return nil
        }
    }
}
