import AppKit
import CodingAgentKit
import TailscodeCore

/// The one tap a `ConnectDiagnosis` offers, wired once for every Mac surface that probes a machine.
/// The checklist and the Servers window both show Core's diagnosis, so what each fix does cannot
/// differ between them: Tailscale opens through the door this Mac's own reading offers, a command
/// for the other machine lands on the pasteboard, and the three that depend on the surface (try
/// again, try another address, the password field) are handed in.
@MainActor
struct MacConnectFix {
    let remedy: TailnetRemedyView
    var tailscale: () -> TailscaleReading?
    var retry: () -> Void
    var retarget: (URL) -> Void
    var revealPassword: () -> Void
    var seePro: () -> Void

    func perform(_ fix: ConnectDiagnosis.Fix) {
        switch fix {
        case .none:
            return
        case .openTailscale:
            openTailscale()
        case .openAppSettings:
            if let url = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(url) }
        case .retry:
            retry()
        case .retryOtherPort(let url), .usePlainHTTP(let url):
            retarget(url)
        case .revealPassword:
            revealPassword()
        case .seePro:
            seePro()
        case .copyCommand(let command):
            RowKit.copyToClipboard(command)
        }
    }

    /// The door Tailscale offers for what this Mac reads, or the Tailscale app, or its download
    /// page when the reading is a healthy one and the diagnosis still names Tailscale (a machine
    /// signed into another account says so from an `up` reading).
    func openTailscale() {
        if let reading = tailscale(), TailnetStatusMac.door(for: reading) != nil {
            remedy.write(reading)
            remedy.enterDoor()
            return
        }
        if let app = TailnetStatusMac.appURL {
            NSWorkspace.shared.open(app)
        } else if let page = URL(string: TailnetStatusMac.downloadPage) {
            NSWorkspace.shared.open(page)
        }
    }
}
