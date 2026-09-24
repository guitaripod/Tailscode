import CodingAgentKit
import Foundation

/// A Mac asks a person before a process reads their Documents, Desktop, Downloads or another app's
/// data, and it asks on the Mac's own screen. A bridge is a daemon nobody is watching, so a grant
/// that was never given is a turn that stalls behind a dialog across the room. Apps ask for what
/// they need the first time they run, as a checklist that notices each switch the moment it is
/// flipped; a server that cannot show its own window gets the same checklist on whichever screen
/// the person is holding, and every word of it is written here.
///
/// The server reads its own grants without ever raising a prompt, and the only thing a client can
/// do about one is ask the machine to open the right pane with the binary beside it — the switch
/// itself is always the person's.
public enum MachinePermissionReading {
    public static let symbol = "lock.shield"
    public static let grantedSymbol = "checkmark.shield"

    /// How often a screen showing a missing grant asks again, so the switch is noticed without a
    /// refresh gesture.
    public static let pollInterval: Duration = .seconds(2)

    /// Whether the checklist has anything to show: a machine that reports grants this build can
    /// explain. Nil (a server too old for the route, or no bridge at all) and Linux show nothing.
    public static func isShown(_ permissions: MachinePermissions?) -> Bool {
        guard let permissions, permissions.platform == .macOS else { return false }
        return !permissions.known.isEmpty
    }

    /// Whether first run should stop and ask before calling the machine ready.
    public static func needsAttention(_ permissions: MachinePermissions?) -> Bool {
        isShown(permissions) && !(permissions?.isComplete ?? true)
    }

    public static func sectionTitle(_ permissions: MachinePermissions) -> String {
        guard let host = permissions.host, !host.isEmpty else { return Localized.text("Mac permissions") }
        return Localized.text("Permissions on %@", host)
    }

    public static func title(_ kind: MachinePermissions.Grant.Kind) -> String {
        switch kind {
        case .fullDiskAccess: return Localized.text("Full Disk Access")
        }
    }

    /// Why the grant is worth giving, in the words of what goes wrong without it.
    public static func purpose(_ kind: MachinePermissions.Grant.Kind) -> String {
        switch kind {
        case .fullDiskAccess:
            return Localized.text(
                "Lets agents read and write your Documents, Desktop, Downloads and other apps' files. Without it, macOS stops a turn at a dialog on the Mac's screen, where nobody is looking.")
        }
    }

    public static func state(_ grant: MachinePermissions.Grant) -> String {
        switch grant.state {
        case .granted: return Localized.text("On")
        case .missing: return Localized.text("Off")
        }
    }

    public static func symbol(_ grant: MachinePermissions.Grant) -> String {
        grant.state == .granted ? grantedSymbol : symbol
    }

    /// A glyph for the text clients.
    public static func glyph(_ grant: MachinePermissions.Grant) -> String {
        grant.state == .granted ? "✓" : "○"
    }

    /// The one line a server row wears about its grants, nil when there is nothing to say.
    public static func line(_ permissions: MachinePermissions?) -> String? {
        guard let permissions, isShown(permissions) else { return nil }
        let missing = permissions.missing.compactMap(\.kind)
        guard let first = missing.first else {
            return Localized.text("Agents can work anywhere in your files")
        }
        return Localized.text("%@ is off — agents will stop at dialogs on the Mac", title(first))
    }

    /// The press. `local` is a client running on the very Mac the server does, where the pane
    /// opens under the person's own pointer.
    public static func action(_ permissions: MachinePermissions, local: Bool) -> String {
        if local { return Localized.text("Open System Settings") }
        if let host = permissions.host, !host.isEmpty {
            return Localized.text("Open on %@", host)
        }
        return Localized.text("Open on the Mac")
    }

    /// What the person has to do once the pane is open, in order. Written for someone who may be
    /// holding a phone in front of the Mac, so the first step says where to look.
    public static func steps(_ permissions: MachinePermissions, local: Bool) -> [String] {
        let binary = executableName(permissions)
        let place: String
        if local {
            place = Localized.text("System Settings is open at Privacy & Security → Full Disk Access.")
        } else if let host = permissions.host, !host.isEmpty {
            place = Localized.text(
                "System Settings is open on %@ at Privacy & Security → Full Disk Access.", host)
        } else {
            place = Localized.text(
                "System Settings is open on the Mac at Privacy & Security → Full Disk Access.")
        }
        return [
            place,
            Localized.text(
                "If %@ is in the list, switch it on. If not, drag it in from the Finder window beside it.",
                binary),
            Localized.text("macOS asks for your password or Touch ID. This screen notices when it's on."),
        ]
    }

    /// Whether the steps are shown: the pane was opened recently and the grant is still off.
    public static func isWaiting(_ permissions: MachinePermissions, now: Date = Date()) -> Bool {
        guard let requestedAt = permissions.requestedAt, !permissions.isComplete else { return false }
        return now.timeIntervalSince(requestedAt) < waitingWindow
    }

    /// Long enough to find the Mac, the window and the switch; short enough that a checklist
    /// opened tomorrow does not claim System Settings is still open.
    public static let waitingWindow: TimeInterval = 10 * 60

    /// Whether `done` is shown: the switch went on after a press this machine still remembers.
    /// Past the same window it is simply the state, and the row's own "On" says so.
    public static func showsDone(_ permissions: MachinePermissions, now: Date = Date()) -> Bool {
        guard let requestedAt = permissions.requestedAt, permissions.isComplete else { return false }
        return now.timeIntervalSince(requestedAt) < waitingWindow
    }

    /// How long first run leaves `done` on screen before it moves on by itself, so the person
    /// sees the switch land rather than a window vanishing under them.
    public static let doneLinger: Duration = .milliseconds(1500)

    /// The line that replaces the steps the moment the switch is noticed.
    public static func done(_ permissions: MachinePermissions) -> String {
        if let host = permissions.host, !host.isEmpty {
            return Localized.text("Done — agents on %@ can work anywhere in your files.", host)
        }
        return Localized.text("Done — agents can work anywhere in your files.")
    }

    /// A request the server refused or could not reach, in words.
    public static let requestFailed = Localized.text(
        "The Mac didn't open System Settings. Open Privacy & Security → Full Disk Access on it and add claude-bridge.")

    /// First run's step: the heading and the sentence under it.
    public static let setupTitle = Localized.text("Let agents into your files")

    public static func setupDetail(_ permissions: MachinePermissions) -> String {
        if let host = permissions.host, !host.isEmpty {
            return Localized.text(
                "%@ is a Mac, and macOS asks before anything reads your folders. One switch lets agents work there without stopping at a dialog nobody sees.",
                host)
        }
        return Localized.text(
            "This server is a Mac, and macOS asks before anything reads your folders. One switch lets agents work there without stopping at a dialog nobody sees.")
    }

    /// First run's way past the step without the grant: nothing breaks, it only asks more.
    public static let skip = Localized.text("Not now")

    public static func executableName(_ permissions: MachinePermissions) -> String {
        guard let executable = permissions.executable, !executable.isEmpty else { return "claude-bridge" }
        return URL(fileURLWithPath: executable).lastPathComponent
    }

    /// Whether a client is running on the same Mac as the server, judged by the machine's own
    /// name — the only fact both ends can read without asking the operating system anything.
    public static func isLocal(_ permissions: MachinePermissions, thisHost: String?) -> Bool {
        guard let host = permissions.host?.lowercased(), !host.isEmpty,
            let thisHost = thisHost?.lowercased(), !thisHost.isEmpty
        else { return false }
        return host == thisHost.replacingOccurrences(of: ".local", with: "")
    }

    /// A screen reader's sentence for a grant row.
    public static func accessibility(_ grant: MachinePermissions.Grant) -> String? {
        guard let kind = grant.kind else { return nil }
        return Localized.text("%@: %@", title(kind), state(grant))
    }
}
