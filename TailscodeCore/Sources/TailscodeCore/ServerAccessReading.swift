import CodingAgentKit
import Foundation

/// A server that wanted no password is not an unprotected server, and a server that refused this
/// device is not always asking for one. Tailscale already knows who every node belongs to, and a
/// bridge on a tailnet asks it rather than asking the person to retype a secret the machine was
/// started with — so the words around a connection have to tell those cases apart: what let this
/// device in, and, when nothing did, whether a password would.
public enum ServerAccessReading {
    public static let symbol = "network.badge.shield.half.filled"

    /// The one line a server row wears about its door. Nil for a server that does not say — an
    /// opencode, or a bridge too old to report it — because a guess here reads as a fact.
    public static func line(_ access: ServerAccess?) -> String? {
        guard let access else { return nil }
        switch access.mode {
        case .tailnet:
            if let login = access.login, !login.isEmpty {
                return Localized.text("Trusted through your tailnet as %@ — no password", login)
            }
            return Localized.text("Trusted through your tailnet — no password")
        case .password:
            return Localized.text("Let in by its password")
        case .open:
            return Localized.text("Open — no password and no tailnet check")
        }
    }

    /// A glyph for the text clients, in the order the modes get safer.
    public static func glyph(_ access: ServerAccess) -> String {
        switch access.mode {
        case .tailnet: return "◉"
        case .password: return "🔒"
        case .open: return "○"
        }
    }

    /// The refusal a client writes where it used to write "wants a password": a machine that
    /// admits only its own tailnet account has no password to give, so the fix is on this device.
    public static func tailnetOnlyTitle(host: String) -> String {
        Localized.text("%@ trusts only its own tailnet", host)
    }

    public static let tailnetOnlyDetail = Localized.text(
        "It answered, but admits only devices signed into the same Tailscale account it runs under — and it has no password. Sign this device into that account, or start the bridge with BRIDGE_PASSWORD."
    )

    /// What a scan row says beside a locked machine.
    public static func suggestionNote(_ suggestion: TailnetScanner.Suggestion) -> String? {
        if suggestion.tailnetOnly { return Localized.text("its tailnet only") }
        if suggestion.requiresAuth { return Localized.text("wants a password") }
        return nil
    }
}
