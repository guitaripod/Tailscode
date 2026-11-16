import CodingAgentKit
import Foundation

/// The words for being quiet at a computer and for the page's own summary, so the three settings
/// pages say the same thing in the same order.
extension NoticeRulesWords {
    public static var deskGroupTitle: String { Localized.text("At your computer") }
    public static var quietAtDeskTitle: String { Localized.text("Stay quiet while I’m at my computer") }
    public static var quietAtDeskSubtitle: String {
        Localized.text("Your Mac or PC tells you instead")
    }
    public static var awayTitle: String { Localized.text("Count me away after") }
    public static var awaySubtitle: String {
        Localized.text("No keyboard or mouse for this long. Locking the screen counts at once.")
    }
    public static var deskGroupDescription: String {
        Localized.text(
            "While Tailscode on your Mac or PC sees you working, this device stays silent and your computer tells you. Anything you leave unread arrives here once you’ve been away for the time above.")
    }

    public static func away(_ seconds: TimeInterval) -> String {
        switch Int(seconds.rounded()) {
        case 60: return Localized.text("1 minute")
        case 120: return Localized.text("2 minutes")
        case 300: return Localized.text("5 minutes")
        case 600: return Localized.text("10 minutes")
        case let other where other % 60 == 0: return Localized.text("%d min", other / 60)
        case let other: return Localized.text("%d s", other)
        }
    }

    public static func awayDetail(_ seconds: TimeInterval) -> String {
        switch Int(seconds.rounded()) {
        case 60: return Localized.text("Hand over quickly. Reading without touching anything may count as away.")
        case 120: return Localized.text("The default: long enough to read, short enough to notice you left.")
        case 300: return Localized.text("For long reads and calls at the desk.")
        case 600: return Localized.text("Only when you have clearly gone.")
        default: return ""
        }
    }

    /// What a phone says about the desks right now, beside the switch.
    public static func deskStatus(
        _ presence: DeskPresence?, awayAfter: TimeInterval, quiet: Bool
    ) -> String {
        guard let presence else {
            return Localized.text("Needs claude-bridge or omp-bridge on one of your machines")
        }
        if let desk = presence.occupied(awayAfter: awayAfter) {
            return quiet
                ? Localized.text("You’re at %@ now, so this device is quiet", deskName(desk))
                : Localized.text("You’re at %@ now", deskName(desk))
        }
        let known = presence.desks.filter { TimeInterval($0.heard) < DeskPresence.staleAfter }
        if let recent = known.min(by: { ($0.idle ?? .max) < ($1.idle ?? .max) }) {
            return recent.locked
                ? Localized.text("%@ is locked, so you’re away", deskName(recent))
                : Localized.text("Away from %@", deskName(recent))
        }
        return Localized.text("No computer is running Tailscode right now")
    }

    private static func deskName(_ desk: DeskPresence.Desk) -> String {
        desk.name.isEmpty ? Localized.text("your computer") : desk.name
    }

    public static var deskReportsTitle: String { Localized.text("Quiet my phone while I’m here") }
    public static var deskReportsSubtitle: String {
        Localized.text("Your phone stays silent while you use this computer and gets anything you leave unread when you go.")
    }

    /// What a computer says about its own reports, beside its switch.
    public static func deskReportStatus(_ status: DeskBeat.Status) -> String {
        guard status.enabled else { return Localized.text("Off. Your phone notifies you wherever you are.") }
        guard let reading = status.reading else { return Localized.text("Starting…") }
        if reading.idle == nil {
            return Localized.text("This desktop doesn’t say when you’re at it, so your phone keeps notifying you")
        }
        if status.asked == 0 || (status.heard == 0 && status.refused == status.asked) {
            return Localized.text("No server here keeps track yet. Update claude-bridge or omp-bridge.")
        }
        if status.heard == 0 {
            return Localized.text("Can’t reach your machines right now. Your phone notifies you until they answer.")
        }
        if reading.locked { return Localized.text("Locked, so your phone notifies you") }
        return status.heard == 1
            ? Localized.text("Telling one machine you’re here")
            : Localized.text("Telling %d machines you’re here", status.heard)
    }

    public static var mutedRowAction: String { Localized.text("Unmute") }
    public static var mutedFooter: String {
        Localized.text(
            "Finished work in these chats ends quietly. Approvals and questions still reach you. Mute a chat from its menu.")
    }
    public static var unnamedChat: String { Localized.text("A chat with no name yet") }

    /// One line saying what the page's choices add up to, in the order the page asks them.
    public static func summary(_ rules: NoticeRules, desk: Bool) -> String {
        var parts: [String] = []
        switch rules.finish {
        case .settled, .everyTurn:
            let base =
                rules.finish == .settled
                ? Localized.text("Finished work") : Localized.text("Every turn")
            parts.append(
                rules.minimumWork >= 1
                    ? Localized.text("%1$@ over %2$@", base, minimum(rules.minimumWork).lowercased())
                    : base)
        case .failures: parts.append(Localized.text("Failures"))
        case .never: break
        }
        if rules.needsYou { parts.append(Localized.text("Approvals and questions")) }
        guard !parts.isEmpty else { return Localized.text("Nothing notifies you") }
        var line = parts.joined(separator: " · ")
        if desk && rules.quietAtDesk {
            line += " · " + Localized.text("Quiet at your computer")
        }
        if !rules.muted.isEmpty {
            line += " · " + mutedCountShort(rules.muted.count)
        }
        return line
    }

    private static func mutedCountShort(_ count: Int) -> String {
        count == 1 ? Localized.text("1 chat muted") : Localized.text("%d chats muted", count)
    }
}
