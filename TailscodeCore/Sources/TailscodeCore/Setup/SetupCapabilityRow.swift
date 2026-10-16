import CodingAgentKit
import Foundation

/// One line of a server screen's Capabilities section: what the machine can do, in what state, and
/// what a tap opens. A capability whose machine can never do it is not a row at all; a machine that
/// has nothing answering for a capability yet gets the single quiet invitation to add it.
public struct SetupCapabilityRow: Sendable, Equatable, Identifiable {
    public enum Opens: Sendable, Equatable {
        case checklist(SetupTarget)
    }

    public let capability: String
    public let title: String
    public let chip: String
    public let line: String
    public let tone: ActivityTone
    public let icon: ActivityIcon
    public let quiet: Bool
    public let opens: Opens

    public var id: String { capability }

    public init(
        capability: String, title: String, chip: String, line: String, tone: ActivityTone, icon: ActivityIcon,
        quiet: Bool, opens: Opens
    ) {
        self.capability = capability
        self.title = title
        self.chip = chip
        self.line = line
        self.tone = tone
        self.icon = icon
        self.quiet = quiet
        self.opens = opens
    }

    public var spoken: String { [title, chip, line].joined(separator: ". ") }

    /// The row for one capability, or `nil` when it should not be shown: nothing has been heard yet,
    /// the machine cannot do it, or it could not be reached.
    public static func row(for snapshot: SetupSnapshot, locale: Locale = .current) -> SetupCapabilityRow? {
        let target = snapshot.target
        let name = SetupReading.name(of: target.capability)
        switch snapshot.phase {
        case .checking where snapshot.report == nil, .unreachable, .wantsPassword:
            return nil
        case .absent:
            return SetupCapabilityRow(
                capability: target.capability, title: addTitle(for: target.capability),
                chip: Localized.text("Set up"), line: addLine(for: target.capability), tone: .quiet,
                icon: ActivityIcon(symbol: "plus.circle", glyph: "+", tone: .quiet, motion: .still), quiet: true,
                opens: .checklist(target))
        default:
            break
        }
        guard snapshot.report?.available == true else { return nil }
        let checklist = SetupChecklist(snapshot: snapshot, locale: locale)
        return SetupCapabilityRow(
            capability: target.capability, title: name, chip: chip(for: checklist.status), line: checklist.headline,
            tone: checklist.tone, icon: checklist.icon, quiet: false, opens: .checklist(target))
    }

    public static func rows(for snapshots: [SetupSnapshot], locale: Locale = .current) -> [SetupCapabilityRow] {
        snapshots.compactMap { row(for: $0, locale: locale) }
    }

    public static func chip(for status: SetupStatus) -> String {
        switch status {
        case .ready: return Localized.text("Ready")
        case .working: return Localized.text("Setting up")
        case .needs: return Localized.text("Needs setup")
        case .checking: return Localized.text("Checking")
        case .unavailable: return Localized.text("Not possible")
        case .unreachable: return Localized.text("Offline")
        case .wantsPassword: return Localized.text("Password")
        }
    }

    public static func addTitle(for capability: String) -> String {
        capability == SetupCapability.voice
            ? Localized.text("Add voice calls") : Localized.text("Add %@", SetupReading.name(of: capability))
    }

    public static func addLine(for capability: String) -> String {
        capability == SetupCapability.voice
            ? Localized.text("Talk to your chats out loud. Needs an NVIDIA GPU with 80 GB.")
            : Localized.text("Not set up on this server yet.")
    }

    public static var sectionTitle: String { Localized.text("Capabilities") }
}
