import Foundation

/// Which side of a silent tailnet is the likelier one to be broken, and what to try, in the order
/// it costs.
///
/// Tailscale on an iPhone or iPad can stop carrying anything while its switch still reads
/// Connected: its receive loop dies after the phone sleeps or changes networks, and its own
/// Warnings screen says MagicSock is not running. From this side that looks exactly like a machine
/// gone to sleep, so "arch is unreachable" sent people to their desk for a fault in their pocket.
/// What a client can see is enough to tell the two apart most of the time: no tailnet address here
/// at all is this device; every machine silent at once while the address is up is this device's
/// Tailscale; some machines answering clears it and leaves the silent ones. One machine, silent,
/// could be either, and the ladder still starts with the step that costs a second.
public struct ReachReading: Equatable, Hashable, Sendable {
    public enum Suspect: Equatable, Hashable, Sendable {
        case offTailnet
        case thisDevice
        case either
        case machines
    }

    public enum Device: Equatable, Hashable, Sendable {
        case iPhone
        case iPad
        case mac
        case linux
    }

    public enum Action: Equatable, Hashable, Sendable {
        case openTailscale
        case updateTailscale
        case retry
    }

    public struct Step: Equatable, Hashable, Sendable {
        public let title: String
        public let detail: String
        public let action: Action?
    }

    public let suspect: Suspect
    public let names: [String]
    public let device: Device

    /// - Parameters:
    ///   - silent: the names of the machines that did not answer.
    ///   - answering: how many configured machines did answer.
    ///   - onTailnet: whether this device holds a tailnet address right now.
    public static func read(
        silent: [String], answering: Int, onTailnet: Bool, device: Device
    ) -> ReachReading? {
        guard !silent.isEmpty else { return nil }
        let suspect: Suspect =
            if !onTailnet { .offTailnet }
            else if answering > 0 { .machines }
            else if silent.count > 1 { .thisDevice }
            else { .either }
        return ReachReading(suspect: suspect, names: silent, device: device)
    }

    public var symbol: String {
        switch suspect {
        case .offTailnet: return "wifi.exclamationmark"
        case .thisDevice, .either: return "network.slash"
        case .machines: return "moon.zzz"
        }
    }

    /// The first thing to press: Tailscale whenever this device may be the cause, because it is
    /// the fix that takes a second and the one no amount of retrying will ever stand in for.
    public var primary: Action {
        suspect == .machines ? .retry : .openTailscale
    }

    public var title: String {
        if suspect == .offTailnet { return Self.offTitle(device) }
        return names.count == 1
            ? Localized.text("%@ is unreachable", names[0])
            : Localized.text("%lld servers are unreachable", names.count)
    }

    public var lead: String {
        let who = Self.list(names)
        switch (suspect, device) {
        case (.offTailnet, _):
            return Localized.text(
                "Nothing can answer until Tailscale is connected here. Open it, sign in to the same account as your other machine, then come back."
            )
        case (.thisDevice, .iPad):
            return Localized.text(
                "None of your machines answer, so the likeliest cause is Tailscale on this iPad. It can stall after the iPad sleeps or changes networks while still showing Connected."
            )
        case (.thisDevice, _):
            return Localized.text(
                "None of your machines answer, so the likeliest cause is Tailscale on this iPhone. It can stall after the phone sleeps or changes networks while still showing Connected."
            )
        case (.either, .iPad):
            return Localized.text(
                "Tailscale on this iPad can stall after it sleeps or changes networks while still showing Connected. If it is not that, %@ is asleep or offline.",
                who)
        case (.either, _):
            return Localized.text(
                "Tailscale on this iPhone can stall after the phone sleeps or changes networks while still showing Connected. If it is not that, %@ is asleep or offline.",
                who)
        case (.machines, _):
            return Localized.text(
                "Your other machines answer, so Tailscale here is working. %@ may be asleep, offline or restarting.",
                who)
        }
    }

    /// The ladder, cheapest first. A step for the machine itself is there only when the machine
    /// may be the cause, and the Tailscale steps only when this device may be.
    public var steps: [Step] {
        switch suspect {
        case .offTailnet:
            return [turnOn]
        case .thisDevice:
            return [toggle, relaunch, restart, update]
        case .either:
            return [toggle, relaunch, restart, update, checkMachine]
        case .machines:
            return [checkMachine, seeInTailscale]
        }
    }

    /// One line for a banner that has room for nothing else: what is wrong, and that a press
    /// explains it.
    public var bannerLine: String {
        Localized.text("%@ — tap for help", title)
    }

    /// The sentence a desktop's chat list adds under its unreachable line. A desk has a menu bar
    /// or a service where a phone has a switch, and its Tailscale stalls far less often, so it is
    /// told the suspect and its one fix rather than handed a ladder.
    public var deskHint: String {
        switch (suspect, device) {
        case (.offTailnet, .linux):
            return Localized.text("Tailscale is off on this computer.")
        case (.offTailnet, _):
            return Localized.text("Tailscale is off on this Mac.")
        case (.thisDevice, .linux):
            return Localized.text(
                "None of your machines answer, so the likelier cause is Tailscale on this computer: restart it, or restart the computer.")
        case (.thisDevice, _):
            return Localized.text(
                "None of your machines answer, so the likelier cause is Tailscale on this Mac: turn it off and on from its menu bar icon.")
        case (.either, .linux):
            return Localized.text(
                "Either Tailscale on this computer has stalled, and restarting it brings it back, or the machine is asleep or offline.")
        case (.either, _):
            return Localized.text(
                "Either Tailscale on this Mac has stalled, and turning it off and on from its menu bar icon brings it back, or the machine is asleep or offline.")
        case (.machines, _):
            return Localized.text("Your other machines answer, so these are likely asleep or offline.")
        }
    }

    private var turnOn: Step {
        Step(
            title: Localized.text("Turn Tailscale on"),
            detail: Localized.text("Open Tailscale and switch it on, then come back."),
            action: .openTailscale)
    }

    private var toggle: Step {
        Step(
            title: Localized.text("Turn Tailscale off and on"),
            detail: Localized.text(
                "Open Tailscale and flip its switch off, then on. A warning there that MagicSock is not running means this is the fix."
            ),
            action: .openTailscale)
    }

    private var relaunch: Step {
        Step(
            title: Localized.text("Close Tailscale and switch the VPN"),
            detail: Localized.text(
                "If it is still stuck, swipe Tailscale away in the app switcher, then turn VPN off and on in Settings."),
            action: nil)
    }

    private var restart: Step {
        Step(
            title: device == .iPad
                ? Localized.text("Restart this iPad") : Localized.text("Restart this iPhone"),
            detail: Localized.text("When nothing else brings it back, a restart does."),
            action: nil)
    }

    private var update: Step {
        Step(
            title: Localized.text("Update Tailscale"),
            detail: Localized.text(
                "This stall is a Tailscale bug on iPhone and iPad, and its updates are where the fixes arrive."),
            action: .updateTailscale)
    }

    private var checkMachine: Step {
        Step(
            title: Localized.text("Check %@", Self.list(names)),
            detail: names.count == 1
                ? Localized.text(
                    "Make sure it is switched on, awake and signed into the same tailnet, then try again.")
                : Localized.text(
                    "Make sure they are switched on, awake and signed into the same tailnet, then try again."),
            action: .retry)
    }

    private var seeInTailscale: Step {
        Step(
            title: Localized.text("See it in Tailscale"),
            detail: Localized.text("Tailscale lists your machines, and one it shows as offline is asleep or switched off."),
            action: .openTailscale)
    }

    private static func offTitle(_ device: Device) -> String {
        switch device {
        case .iPhone: return Localized.text("Tailscale is off on this iPhone")
        case .iPad: return Localized.text("Tailscale is off on this iPad")
        case .mac: return Localized.text("Tailscale is off on this Mac.")
        case .linux: return Localized.text("Tailscale is off on this computer.")
        }
    }

    private static func list(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }
}
