import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Voice demo")
struct VoiceDemoTests {
    @Test("The script is forty seconds of ordered cues; only the first loop opens the line and glitches")
    func script() {
        let first = VoiceDemoScript.cues(loop: 0)
        let second = VoiceDemoScript.cues(loop: 1)
        #expect(first.map(\.at) == first.map(\.at).sorted())
        #expect(first.allSatisfy { $0.at >= 0 && $0.at < VoiceDemoScript.loopLength })
        func frames(_ cues: [VoiceDemoScript.Cue]) -> [VoiceServerMessage] { cues.map(\.message) }
        let firstFrames = frames(first)
        let secondFrames = frames(second)
        #expect(firstFrames.contains { if case .ready = $0 { return true } else { return false } })
        #expect(!secondFrames.contains { if case .ready = $0 { return true } else { return false } })
        #expect(firstFrames.contains { if case .degraded = $0 { return true } else { return false } })
        #expect(!secondFrames.contains { if case .degraded = $0 { return true } else { return false } })
        for list in [firstFrames, secondFrames] {
            #expect(list.contains { if case .dispatch = $0 { return true } else { return false } })
            #expect(list.contains { if case .recycled = $0 { return true } else { return false } })
            #expect(!list.contains { if case .say = $0 { return true } else { return false } })
            #expect(!list.contains { if case .phase(.speaking, _) = $0 { return true } else { return false } })
            #expect(list.contains { if case .user(_, _, true) = $0 { return true } else { return false } })
        }
    }

    @Test("The level rises and falls with the scripted lines and is zero in between and before the call")
    func levels() {
        #expect(VoiceDemoScript.userLevel(at: -1) == 0)
        #expect(VoiceDemoScript.userLevel(at: 1) == 0)
        #expect(VoiceDemoScript.userLevel(at: 8) == 0)
        let hearing = stride(from: 2.0, through: 4.2, by: 0.05).map(VoiceDemoScript.userLevel(at:))
        #expect(hearing.max()! > 0.5)
        #expect(Set(hearing.map { ($0 * 100).rounded() }).count > 5)
        #expect(hearing.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(VoiceDemoScript.userLevel(at: 40 + 3) > 0)
    }

    @Test("Played through the session, the script shows every face a listening call has, sends both requests and chimes once")
    func everyFace() async {
        let clock = ManualVoiceClock()
        let stage = VoiceDemo.stage(clock: clock)
        let prompts = Prompts()
        let session = VoiceCallSession(
            endpoint: VoiceEndpoint(host: "studio.tailnet-demo.ts.net"), client: .linux, appVersion: "1",
            title: "Demo", transport: stage.transport, capture: stage.capture, playback: stage.playback,
            send: { prompts.send($0) }, stopTurn: { prompts.stop() }, clock: clock)
        let recorder = Recorder()
        let watcher = recorder.watch(session.snapshots)
        await session.start()
        #expect(stage.capture.isRunning)

        var microphone: [Double] = []
        var chimes = 0
        for step in 1...270 {
            await clock.advance(by: 0.1)
            microphone.append(stage.capture.level)
            if step == 46 { await session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Running a command.", turn: 1)) }
            if step == 110 {
                await session.update(agent: VoiceAgentSnapshot(busy: false, digest: "Done. Three tests failed.", turn: 2))
                chimes = await session.current().finishedChimes
            }
        }
        await session.hangUp()
        _ = await watcher.value

        let faces = recorder.faces
        func saw(_ matches: (VoiceCallFace) -> Bool) -> Bool { faces.contains(where: matches) }
        #expect(saw { $0 == .connecting })
        #expect(saw { $0 == .listening })
        #expect(saw { $0 == .hearing })
        #expect(!saw { $0 == .speaking })
        #expect(saw { $0 == .working })
        #expect(saw { $0 == .degraded(.engineError) })
        #expect(saw { $0 == .ended })
        #expect(faces.last == .ended)

        #expect(prompts.sent == [VoiceDemoScript.firstQuestion, VoiceDemoScript.secondQuestion])
        let lines = recorder.snapshots.last?.lines ?? []
        #expect(lines.contains { $0.kind == .you && $0.text == VoiceDemoScript.firstQuestion && $0.final })
        #expect(lines.contains { $0.kind == .you && $0.text == VoiceDemoScript.secondQuestion && $0.final })
        #expect(lines.allSatisfy { $0.kind == .you })
        #expect(chimes == 1)
        #expect(stage.playback.chunksPlayed == 0)
        #expect(microphone.max()! > 0.5)
        #expect(!stage.capture.isRunning)
        #expect(recorder.snapshots.last?.end == .hungUp)
    }
}
