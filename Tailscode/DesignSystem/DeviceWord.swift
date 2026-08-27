import UIKit

/// The words that name the device they are read on. Onboarding argues from "this iPhone";
/// on an iPad every one of those sentences must say iPad, and the hero must draw one.
@MainActor
enum DeviceWord {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    static var heroSymbol: String { isPad ? "ipad" : "iphone" }

    static var thisDevice: String {
        isPad ? String(localized: "This iPad") : String(localized: "This iPhone")
    }

    static var tailscaleStep: String {
        isPad
            ? String(localized: "Tailscale on this iPad")
            : String(localized: "Tailscale on this iPhone")
    }

    static var connectStep: String {
        isPad
            ? String(localized: "Connect this iPad")
            : String(localized: "Connect this iPhone")
    }

    static var onTailnetSameAccount: String {
        isPad
            ? String(
                localized:
                    "This iPad is on your tailnet. The computer that runs the agent has to be signed into the same account."
            )
            : String(
                localized:
                    "This iPhone is on your tailnet. The computer that runs the agent has to be signed into the same account."
            )
    }

    static var onTailnetAnnouncement: String {
        isPad
            ? String(localized: "This iPad is on your tailnet.")
            : String(localized: "This iPhone is on your tailnet.")
    }

    static func onTailnetAccessibility(address: String) -> String {
        isPad
            ? String(
                localized: "This iPad is on your tailnet at \(address), able to reach your machine.")
            : String(
                localized:
                    "This iPhone is on your tailnet at \(address), able to reach your machine.")
    }

    static var offTailnetAccessibility: String {
        isPad
            ? String(
                localized: "This iPad is not on your tailnet, so it cannot reach your machine yet.")
            : String(
                localized:
                    "This iPhone is not on your tailnet, so it cannot reach your machine yet.")
    }

    static var linkAccessibility: String {
        isPad
            ? String(localized: "Your iPad reaches your machine over an encrypted Tailscale link.")
            : String(
                localized: "Your iPhone reaches your machine over an encrypted Tailscale link.")
    }
}
