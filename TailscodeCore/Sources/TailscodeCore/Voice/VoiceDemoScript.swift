import CodingAgentKit
import Foundation

/// The demo is the real thing minus the machine. This is its call: forty seconds of cues that the
/// demo transport plays and the demo audio listens to, so a first-run person and App Review hear
/// the call work with no gateway, no model and no network.
public enum VoiceDemoScript {
    public static let loopLength: TimeInterval = 40
    public static let chunkInterval: TimeInterval = 0.16

    public struct Cue: Sendable, Equatable {
        public enum Step: Sendable, Equatable {
            case frame(VoiceServerMessage)
            case silence
        }

        public let at: TimeInterval
        public let step: Step
    }

    public static let hearingWindows: [ClosedRange<TimeInterval>] = [2.0...4.2, 12.0...13.8]
    public static let speakingWindows: [ClosedRange<TimeInterval>] = [5.2...7.4, 14.6...18.4]

    static let firstQuestion = "Can you run the tests and tell me what fails?"
    static let secondQuestion = "What is it doing now?"
    static let firstAnswer = "Okay, running the tests now."
    static let secondAnswer = "It is running the test suite. Three of forty are left."

    public static func cues(loop: Int) -> [Cue] {
        var cues: [Cue] = []
        func frame(_ at: TimeInterval, _ message: VoiceServerMessage) {
            cues.append(Cue(at: at, step: .frame(message)))
        }
        func phase(_ at: TimeInterval, _ phase: VoicePhase) { frame(at, .phase(phase, at: at)) }
        func user(_ at: TimeInterval, _ id: String, _ text: String, final: Bool = false) {
            frame(at, .user(id: id, text: text, final: final))
        }
        func say(_ at: TimeInterval, _ text: String, final: Bool = false) {
            frame(at, .say(text: text, final: final))
        }
        func voice(_ window: ClosedRange<TimeInterval>) {
            var at = window.lowerBound
            while at < window.upperBound {
                cues.append(Cue(at: at, step: .silence))
                at += chunkInterval
            }
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
        phase(5.2, .speaking)
        voice(speakingWindows[0])
        say(5.6, "Okay,")
        say(6.3, "Okay, running the tests")
        say(7.4, firstAnswer, final: true)
        phase(7.6, .listening)

        phase(12.0, .hearing)
        user(12.2, "u2-\(loop)", "What is it")
        user(13.0, "u2-\(loop)", "What is it doing")
        user(13.6, "u2-\(loop)", secondQuestion, final: true)
        phase(13.8, .listening)
        phase(14.6, .speaking)
        voice(speakingWindows[1])
        say(15.4, "It is running the")
        say(16.8, "It is running the test suite.")
        say(18.4, secondAnswer, final: true)
        phase(18.6, .listening)

        if loop == 0 {
            frame(24.0, .degraded(.runaway, recovering: true))
            phase(24.0, .degraded)
            phase(26.5, .listening)
        }
        frame(33.0, .recycled)
        return cues.sorted { $0.at < $1.at }
    }

    public static func userLevel(at time: TimeInterval) -> Double {
        level(at: time, windows: hearingWindows, rate: 7.3)
    }

    public static func voiceLevel(at time: TimeInterval) -> Double {
        level(at: time, windows: speakingWindows, rate: 5.1)
    }

    private static func level(at time: TimeInterval, windows: [ClosedRange<TimeInterval>], rate: Double) -> Double {
        guard time >= 0 else { return 0 }
        let phase = time.truncatingRemainder(dividingBy: loopLength)
        guard let window = windows.first(where: { $0.contains(phase) }) else { return 0 }
        let edge = min(phase - window.lowerBound, window.upperBound - phase, 0.3) / 0.3
        let wobble = 0.5 + 0.5 * abs(sin(phase * rate))
        return min(1, max(0, (0.2 + 0.7 * wobble) * edge))
    }
}
