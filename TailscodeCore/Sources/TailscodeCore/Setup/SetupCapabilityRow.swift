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
        if let title = SetupReaders.shared.reader(for: capability)?.addTitle { return title }
        return Localized.text("Add %@", SetupReading.name(of: capability))
    }

    public static func addLine(for capability: String) -> String {
        if let line = SetupReaders.shared.reader(for: capability)?.addLine { return line }
        return Localized.text("Not set up on this server yet.")
    }

    public static var sectionTitle: String { Localized.text("Capabilities") }
}

/// Which capabilities a server screen asks each machine about, and where each one is answered. Voice
/// is answered by the gateway on its own port; images and video by the client's own doctor, asked of
/// the renderer the person chose for that server or else of the server's own host on ComfyUI's port;
/// a capability added later names its capability here and is answered by whatever source is
/// registered for it on the desk.
public enum SetupTargets {
    public nonisolated(unsafe) static var listed: [String] = [SetupCapability.voice, SetupCapability.media]

    public static func targets(
        forProfileURL url: URL, profileID: String? = nil,
        filed: (String) -> ForgeEndpoint? = { ForgeStore.endpoint(forProfile: $0) }
    ) -> [SetupTarget] {
        listed.compactMap { capability in
            if capability == SetupCapability.voice {
                return VoiceEndpoint(profileURL: url).map(SetupTarget.voice)
            }
            guard let host = DelegateAccess.host(of: url).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            if capability == SetupCapability.media {
                if VoiceDemo.isDemoHost(host) { return nil }
                let renderer = profileID.flatMap(filed) ?? ForgeEndpoint(host: host)
                return SetupTarget.media(renderer)
            }
            return SetupTarget(host: host, capability: capability)
        }
    }
}
