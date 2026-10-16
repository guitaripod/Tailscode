import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension MainWindow {
    /// `setup=<state>` puts the voice checklist on screen in one of its states with no machine behind
    /// it (`ready`, `command`, `blocker`, `downloading`, `starting`, `failed`, `unavailable`,
    /// `unreachable`, `absent`, `checking`, `password`); `setup=demo` opens the scripted setup the
    /// demo hosts play, through the real desk; `setup=voice` opens the live checklist for the active
    /// chat's server; `setup=media`, `setup=media:video` and `setup=media:pictures` open the images
    /// and video checklist for the renderer in force, led by video, by pictures or by neither;
    /// `setup=renderer:host:port` points renders at a machine first, filed against every server as the picker would;
    /// `setup=press` presses the primary button; `setup=change` presses Change, which opens the
    /// renderer picker; `setup=caps` opens the server screen with every server expanded;
    /// `setup=close` closes it.
    func driveSetup(_ argument: String) {
        let parent = windowWidget
        switch argument {
        case "close":
            SetupWindow.dismiss()
        case "demo":
            let host = DelegateDemo.hosts.sorted().first ?? ""
            SetupWindow.present(target: SetupTarget(host: host, capability: SetupCapability.voice), parent: parent)
        case "voice":
            let entry = activePane.callEntry
            let target: SetupTarget
            if let entry, let live = SetupRunner.shared.voiceTarget(for: entry) {
                target = live
            } else {
                target = SetupTarget(host: entry?.host ?? SetupFixtures.host, capability: SetupCapability.voice)
            }
            SetupWindow.present(target: target, parent: parent)
        case "media", "media:video", "media:pictures":
            let focus: SetupFocus? = argument == "media:video" ? .video : argument == "media:pictures" ? .pictures : nil
            MediaChecklistFlow.open(endpoint: ForgeRunner.shared.endpoint ?? ForgeStore.endpoint(), focus: focus, parent: parent)
        case "change":
            SetupWindow.current?.viewForHarness.onChange?()
        case _ where argument.hasPrefix("renderer:"):
            if case .endpoint(let endpoint) = ForgeEndpoint.read(String(argument.dropFirst("renderer:".count))) {
                let renderer = ForgeRenderer(endpoint: endpoint)
                ForgeStore.remember(renderer)
                Task {
                    for profile in await ServerDirectory.shared.profiles() {
                        ForgeStore.remember(renderer, forProfile: profile.id)
                    }
                    Gtk.onMain { ForgeRunner.shared.pointAtStoredRenderer() }
                }
            }
        case "press":
            if let primary = SetupWindow.current?.checklist?.primary {
                SetupWindow.current?.viewForHarness.onPrimary?(primary)
            }
        case "caps":
            presentServers(expandingEverything: true)
        default:
            if let snapshot = SetupFixtures.snapshot(named: argument) {
                SetupWindow.present(target: snapshot.target, parent: parent, fixture: snapshot)
            } else {
                FileHandle.standardOutput.write(Data("SETUP unknown state \(argument)\n".utf8))
                return
            }
        }
        let line = SetupWindow.current?.reading ?? "closed"
        FileHandle.standardOutput.write(Data("SETUP \(line)\n".utf8))
    }
}
