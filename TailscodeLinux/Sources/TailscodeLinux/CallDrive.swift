import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension MainWindow {
    /// `call=demo`, `call=press`, `call=hangup`, `call=mute`, `call=reading` and `call=endpoint=<ws://host:port>`
    /// (which points the pane's chat at a real gateway, because a demo-world chat's host is never redirected)
    /// act on the active pane's call the
    /// way a press would, and `reach=<state>` makes every control read a gateway state the machine
    /// is not in, so the control can be looked at in each. `call=demo` points the pane at a demo
    /// host's scripted call, which needs no gateway and no audio device.
    func driveCall(_ argument: String) {
        let call = activePane.call
        switch argument {
        case "demo":
            VoiceCallRunner.forcedEndpoint = VoiceEndpoint(host: DelegateDemo.hosts.sorted().first ?? "")
            VoiceCallRunner.forcedReach = nil
            call.refresh()
            call.pressEntry()
        case "press":
            call.pressEntry()
        case "hangup":
            VoiceCallRunner.shared.hangUp()
        case "mute":
            call.strip.pressMute()
        case "unforce":
            VoiceCallRunner.forcedEndpoint = nil
            VoiceCallRunner.forcedReach = nil
            call.refresh()
        default:
            if argument.hasPrefix("endpoint=") {
                let address = String(argument.dropFirst("endpoint=".count))
                VoiceCallRunner.forcedEndpoint = VoiceEndpoint.override(in: [VoiceEndpoint.overrideKey: address])
                VoiceCallRunner.forcedReach = nil
                call.chatChanged()
            }
        }
        FileHandle.standardOutput.write(Data("CALL \(call.reading) \(VoiceCallRunner.shared.audioReading)\n".utf8))
    }

    func driveReach(_ argument: String) {
        let reach: VoiceReach?
        switch argument {
        case "ready": reach = .ready(gateway: "0.1.0")
        case "unknown": reach = .unknown
        case "checking": reach = .checking
        case "loading": reach = .loading
        case "busy": reach = .busy
        case "noGateway": reach = .noGateway
        case "tooOld": reach = .tooOld(protocol: 0)
        case "tooNew": reach = .tooOld(protocol: 99)
        case "engineDown": reach = .engineDown(detail: "CUDA out of memory")
        case "wantsPassword": reach = .wantsPassword
        case "unreachable": reach = .unreachable("the machine could not be reached")
        default: reach = nil
        }
        VoiceCallRunner.forcedReach = reach
        if VoiceCallRunner.forcedEndpoint == nil {
            VoiceCallRunner.forcedEndpoint = VoiceEndpoint(host: "voice-test.invalid")
        }
        splitHost.eachPane { $0.call.refresh() }
        FileHandle.standardOutput.write(Data("REACH \(argument) \(activePane.call.reading)\n".utf8))
    }
}

extension MainWindow {
    /// `motion=off|on` is the harness's hand on the desk's animation switch, which the app itself
    /// never writes.
    func driveMotion(_ argument: String) {
        tailscode_set_animations_enabled(argument == "off" ? 0 : 1)
        tailscode_notify_animations()
        FileHandle.standardOutput.write(Data("MOTION allowed=\(RepeatingMotion.allowed)\n".utf8))
    }

    /// `callshow=<face>[,long][,muted]` lays a still snapshot on the active pane's strip with no
    /// call behind it, so a face, a long caption and a muted control can be looked at in a pane of
    /// any width. `callshow=off` takes it down.
    func driveCallShow(_ argument: String) {
        let call = activePane.call
        let parts = argument.split(separator: ",").map(String.init)
        guard let name = parts.first else { return }
        if name == "off" {
            call.strip.dismiss()
            return
        }
        let faces: [String: VoiceCallFace] = [
            "connecting": .connecting, "listening": .listening, "hearing": .hearing,
            "speaking": .speaking, "working": .working, "degraded": .degraded(.runaway), "ended": .ended,
        ]
        guard let face = faces[name] else { return }
        let long = parts.contains("long")
        let you = long
            ? "can you look at why the reconnect test is flaky on the build machine and tell me whether it is the backoff or the jitter source that makes it fail only on Tuesdays"
            : "Can you run the tests and tell me what fails?"
        let voice = long
            ? "Okay, I will look at the reconnect test first. It fails only when the jitter source returns the same value twice in a row, which is why it looks like Tuesday. I am reading the suite now and will say what I find in a moment."
            : "Okay, running the tests now."
        let degraded = face == .degraded(.runaway) ? VoiceCallDegradation(reason: .runaway, recovering: true) : nil
        let ended = face == .ended
        let snapshot = VoiceCallSnapshot(
            face: face,
            lines: [
                VoiceCallLine(id: "u", kind: .you, text: you, final: name != "hearing"),
                VoiceCallLine(id: "v", kind: .voice, text: voice, final: name != "speaking"),
            ],
            startedAt: Date().addingTimeInterval(-754), degraded: degraded, muted: parts.contains("muted"),
            agentBusy: face == .working, end: ended ? .lost : nil,
            endLine: ended ? VoiceCallReading.end(.lost, client: .linux) : nil)
        call.strip.apply(snapshot, level: { 0.65 })
        call.strip.setAgent(kind: .usingTool(name: "Bash", kind: .shell), text: "Working. Running a command.")
        FileHandle.standardOutput.write(Data("CALLSHOW \(call.strip.report)\n".utf8))
    }
}

extension MainWindow {
    /// `callnarrow=<width>` opens a window of exactly that width holding nothing but a strip with a
    /// long caption, which is how a pane at its narrowest is looked at: a split pane is parked or
    /// squeezed by the tiling before it is ever as narrow as the strip's floor.
    func driveCallNarrow(_ argument: String) {
        let width = Int32(argument) ?? 300
        let tally = CallTally()
        let strip = CallStripView(reportLines: { [] }, mute: { tally.mutes.append($0) }, hangUp: { tally.hangUps += 1 })
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), width, 280)
        gtk_widget_set_size_request(window, width, -1)
        gtk_window_set_child(ptr(window), strip.widget)
        gtk_window_present(ptr(window))
        let snapshot = VoiceCallSnapshot(
            face: .speaking,
            lines: [
                VoiceCallLine(id: "u", kind: .you, text: "can you look at why the reconnect test is flaky on the build machine", final: true),
                VoiceCallLine(id: "v", kind: .voice, text: "Okay, I will look at the reconnect test first. It fails only when the jitter source returns the same value twice.", final: false),
            ],
            startedAt: Date().addingTimeInterval(-3725))
        strip.apply(snapshot, level: { 0.6 })
        strip.setAgent(kind: .usingTool(name: "Bash", kind: .shell), text: "Working. Running a command.")
        Gtk.after(900) {
            Gtk.onMain {
                FileHandle.standardOutput.write(
                    Data("CALLNARROW window=\(width) strip=\(gtk_widget_get_width(strip.widget)) \(strip.report)\n".utf8))
            }
        }
    }
}

final class CallTally: @unchecked Sendable {
    var mutes: [Bool] = []
    var hangUps = 0
}
