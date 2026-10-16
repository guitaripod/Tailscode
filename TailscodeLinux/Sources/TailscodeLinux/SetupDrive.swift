import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension MainWindow {
    /// `setup=<state>` puts the voice checklist on screen in one of its states with no machine behind
    /// it (`ready`, `command`, `blocker`, `downloading`, `starting`, `failed`, `unavailable`,
    /// `unreachable`, `absent`, `checking`, `password`); `setup=demo` opens the scripted setup the
    /// demo hosts play, through the real desk; `setup=voice` and `setup=media` open the live
    /// checklist for the active chat's server; `setup=press` presses the primary button;
    /// `setup=caps` opens the server screen with every server expanded; `setup=close` closes it.
    func driveSetup(_ argument: String) {
        let parent = windowWidget
        switch argument {
        case "close":
            SetupWindow.dismiss()
        case "demo":
            let host = DelegateDemo.hosts.sorted().first ?? ""
            SetupWindow.present(target: SetupTarget(host: host, capability: SetupCapability.voice), parent: parent)
        case "voice", "media":
            let capability = argument == "voice" ? SetupCapability.voice : "media"
            let entry = activePane.callEntry
            let target: SetupTarget
            if capability == SetupCapability.voice, let entry, let live = SetupRunner.shared.voiceTarget(for: entry) {
                target = live
            } else {
                target = SetupTarget(host: entry?.host ?? SetupFixtures.host, capability: capability)
            }
            SetupWindow.present(target: target, parent: parent)
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
