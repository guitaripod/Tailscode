import Foundation

/// The setup steps as a message a person can carry to the other computer.
///
/// Setup is typed on the machine that will run the agent, not on the phone, and that machine is
/// often across the room with nothing connecting it to the phone but the person holding both. The
/// text is the steps the setup shows — the commands verbatim, so what lands in Notes or Messages
/// can be pasted straight into a terminal — and ends on what the machine prints for the phone to
/// read, so nobody has to carry an address back by hand.
public enum SetupHandoff: Sendable {
    public static let tailscaleDownloadURL = "https://tailscale.com/download"

    public static func message(installCommand: String) -> String {
        [
            Localized.text("Set up Tailscale and my coding agent on this computer"),
            Localized.text(
                "1. Install Tailscale on this computer and sign in with the same account as my phone:\n%@",
                tailscaleDownloadURL),
            Localized.text(
                "2. Run this in a terminal on this computer:\n%@", installCommand),
            Localized.text(
                "3. When it finishes it prints a code and a link. Scan the code with Tailscode on the phone, or send the link to it."
            ),
        ].joined(separator: "\n\n")
    }

    public static var action: String { Localized.text("Send these steps to my computer") }
}
