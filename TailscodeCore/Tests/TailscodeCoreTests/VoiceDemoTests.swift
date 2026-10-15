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
        func frames(_ cues: [VoiceDemoScript.Cue]) -> [VoiceServerMessage] {
            cues.compactMap { if case .frame(let message) = $0.step { return message } else { return nil } }
        }
        let firstFrames = frames(first)
        let secondFrames = frames(second)
        #expect(firstFrames.contains { if case .ready = $0 { return true } else { return false } })
        #expect(!secondFrames.contains { if case .ready = $0 { return true } else { return false } })
        #expect(firstFrames.contains { if case .degraded = $0 { return true } else { return false } })
        #expect(!secondFrames.contains { if case .degraded = $0 { return true } else { return false } })
        for list in [firstFrames, secondFrames] {
            #expect(list.contains { if case .dispatch = $0 { return true } else { return false } })
            #expect(list.contains { if case .recycled = $0 { return true } else { return false } })
            #expect(list.contains { if case .say(_, true) = $0 { return true } else { return false } })
            #expect(list.contains { if case .user(_, _, true) = $0 { return true } else { return false } })
        }
        #expect(first.contains { $0.step == .silence })
    }

    @Test("The levels rise and fall with the scripted lines and are zero in between and before the call")
    func levels() {
        #expect(VoiceDemoScript.userLevel(at: -1) == 0)
        #expect(VoiceDemoScript.userLevel(at: 1) == 0)
        #expect(VoiceDemoScript.voiceLevel(at: 3) == 0)
        let hearing = stride(from: 2.0, through: 4.2, by: 0.05).map(VoiceDemoScript.userLevel(at:))
        #expect(hearing.max()! > 0.5)
        #expect(Set(hearing.map { ($0 * 100).rounded() }).count > 5)
        let speaking = stride(from: 5.2, through: 7.4, by: 0.05).map(VoiceDemoScript.voiceLevel(at:))
        #expect(speaking.max()! > 0.5)
        #expect((hearing + speaking).allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(VoiceDemoScript.userLevel(at: 40 + 3) > 0)
    }

    @Test("Played through the session, the script shows every face and sends the scripted prompt")
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
        var speaker: [Double] = []
        for step in 1...270 {
            await clock.advance(by: 0.1)
            microphone.append(stage.capture.level)
            speaker.append(stage.playback.level)
            if step == 46 { await session.update(agent: VoiceAgentSnapshot(busy: true, digest: "Working. Running a command.", turn: 1)) }
        }
        await session.hangUp()
        _ = await watcher.value

        let faces = recorder.faces
        func saw(_ matches: (VoiceCallFace) -> Bool) -> Bool { faces.contains(where: matches) }
        #expect(saw { $0 == .connecting })
        #expect(saw { $0 == .listening })
        #expect(saw { $0 == .hearing })
        #expect(saw { $0 == .speaking })
        #expect(saw { $0 == .working })
        #expect(saw { $0 == .degraded(.runaway) })
        #expect(saw { $0 == .ended })
        #expect(faces.last == .ended)

        #expect(prompts.sent == [VoiceDemoScript.firstQuestion])
        let lines = recorder.snapshots.last?.lines ?? []
        #expect(lines.contains { $0.kind == .you && $0.text == VoiceDemoScript.firstQuestion && $0.final })
        #expect(lines.contains { $0.kind == .voice && $0.text == VoiceDemoScript.firstAnswer && $0.final })
        #expect(stage.playback.chunksPlayed > 20)
        #expect(microphone.max()! > 0.5)
        #expect(speaker.max()! > 0.5)
        #expect(!stage.capture.isRunning)
        #expect(recorder.snapshots.last?.end == .hungUp)
    }
}
