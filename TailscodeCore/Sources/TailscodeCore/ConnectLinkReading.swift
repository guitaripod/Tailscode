import CodingAgentKit
import Foundation

/// Every word a link says to a person, written once for the three clients.
public enum ConnectLinkReading {
    public struct Message: Sendable, Equatable {
        public let title: String
        public let detail: String
    }

    public static func rejection(_ rejection: ConnectLink.Rejection) -> Message {
        switch rejection {
        case .empty:
            return Message(
                title: Localized.text("Nothing to read yet"),
                detail: Localized.text(
                    "Paste the link your machine printed. It starts with tailscode://connect."))
        case .notALink:
            return Message(
                title: Localized.text("That is not a Tailscode link"),
                detail: Localized.text(
                    "The link your machine prints starts with tailscode://connect. Paste that whole line."
                ))
        case .wrongAction:
            return Message(
                title: Localized.text("This link asks for something else"),
                detail: Localized.text(
                    "Tailscode can only open a link that connects a machine. Print a fresh one on your machine."
                ))
        case .malformed:
            return Message(
                title: Localized.text("That link is damaged"),
                detail: Localized.text(
                    "Part of it is missing or garbled, which usually means it was cut short when it was copied. Print it again on your machine and paste the whole line."
                ))
        }
    }

    public static func displayName(_ link: PairingLink) -> String {
        link.name ?? link.host
    }

    public static func headline(_ link: PairingLink) -> String {
        Localized.text("Add %@", displayName(link))
    }

    public static func agentLine(_ link: PairingLink) -> String {
        Localized.text(
            "%@ at %@", link.agent.agentType.displayName, "\(link.bracketedHost):\(link.port)")
    }

    public static func notOnTailnet(_ link: PairingLink) -> String {
        Localized.text(
            "This address is not on a tailnet: %@. Tailscode connects through Tailscale, so check that it is right before you go on.",
            link.host)
    }

    public static var connectAnyway: String { Localized.text("Connect anyway") }

    public static var savedNothing: String {
        Localized.text("Saved nothing yet. Nothing is kept until you press Connect.")
    }

    public static var keyNote: String {
        Localized.text(
            "The link carries this machine's password. It is kept on this device, and only after you press Connect."
        )
    }

    public static var addQuestion: String { Localized.text("Add this machine?") }

    public static var addMachine: String { Localized.text("Add a machine") }

    public static var addMachineDetail: String {
        Localized.text(
            "Paste the link your machine printed, or install the agent on a computer. Tailscode checks each step.")
    }

    public static func addDetail(_ link: PairingLink) -> String {
        Localized.text("A link wants to add %@ to Tailscode.", displayName(link))
    }

    public static func alreadyAdded(_ name: String) -> String {
        Localized.text("%@ is already added. Opening it instead of adding it twice.", name)
    }

    public static var add: String { Localized.text("Add") }
    public static var notNow: String { Localized.text("Not now") }
}
