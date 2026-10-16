import CodingAgentKit
import Foundation

/// The demo is the real thing minus the machine. This is its call: forty seconds of cues that the
/// demo transport plays and the demo audio listens to, so a first-run person and App Review see the
/// call work with no gateway, no model and no network. The model only listens, so the script has
/// two requests heard word by word and sent to the agent; the agent working and the chime that says
/// it finished come from the conversation the client is already holding.
public enum VoiceDemoScript {
    public static let loopLength: TimeInterval = 40
    public static let chunkInterval: TimeInterval = 0.16

    public struct Cue: Sendable, Equatable {
        public let at: TimeInterval
        public let message: VoiceServerMessage
    }

    public static let hearingWindows: [ClosedRange<TimeInterval>] = [2.0...4.2, 12.0...13.8]

    static let firstQuestion = "Can you run the tests and tell me what fails?"
    static let secondQuestion = "And then fix whatever fails"

    public static func cues(loop: Int) -> [Cue] {
        var cues: [Cue] = []
        func frame(_ at: TimeInterval, _ message: VoiceServerMessage) {
            cues.append(Cue(at: at, message: message))
        }
        func phase(_ at: TimeInterval, _ phase: VoicePhase) { frame(at, .phase(phase, at: at)) }
        func user(_ at: TimeInterval, _ id: String, _ text: String, final: Bool = false) {
            frame(at, .user(id: id, text: text, final: final))
        }

        if loop == 0 {
            frame(0, .ready(.init(gateway: VoiceDemo.gatewayVersion, model: VoiceDemo.modelName)))
            phase(0.3, .listening)
        } else {
            phase(0, .listening)
        }
        phase(2.0, .hearing)
        user(2.2, "u1-\(loop)", "Can you")
        user(2.7, "u1-\(loop)", "Can you run the tests")
        user(3.3, "u1-\(loop)", "Can you run the tests and tell me")
        user(3.8, "u1-\(loop)", "Can you run the tests and tell me what fails")
        user(4.2, "u1-\(loop)", firstQuestion, final: true)
        phase(4.3, .listening)
        frame(4.5, .dispatch(id: "d1-\(loop)", text: firstQuestion))

        phase(12.0, .hearing)
        user(12.2, "u2-\(loop)", "And then")
        user(13.0, "u2-\(loop)", "And then fix whatever")
        user(13.6, "u2-\(loop)", secondQuestion, final: true)
        phase(13.8, .listening)
        frame(14.0, .dispatch(id: "d2-\(loop)", text: secondQuestion))

        if loop == 0 {
            frame(24.0, .degraded(.engineError, recovering: true))
            phase(24.0, .degraded)
            phase(26.5, .listening)
        }
        frame(33.0, .recycled)
        return cues.sorted { $0.at < $1.at }
    }

    public static func userLevel(at time: TimeInterval) -> Double {
        guard time >= 0 else { return 0 }
        let phase = time.truncatingRemainder(dividingBy: loopLength)
        guard let window = hearingWindows.first(where: { $0.contains(phase) }) else { return 0 }
        let edge = min(phase - window.lowerBound, window.upperBound - phase, 0.3) / 0.3
        let wobble = 0.5 + 0.5 * abs(sin(phase * 7.3))
        return min(1, max(0, (0.2 + 0.7 * wobble) * edge))
    }
}
