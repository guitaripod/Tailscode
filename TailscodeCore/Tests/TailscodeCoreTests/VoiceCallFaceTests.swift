import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Voice call faces and words")
struct VoiceCallFaceTests {
    private func face(
        _ phase: VoicePhase, busy: Bool = false, _ connection: VoiceCallConnection = .live,
        reason: VoiceDegradedReason? = nil
    ) -> VoiceCallFace {
        VoiceCallFace.read(phase: phase, agentBusy: busy, connection: connection, degraded: reason)
    }

    @Test("The phase, the agent and the line read down to one face")
    func mapping() {
        #expect(face(.connecting) == .connecting)
        #expect(face(.listening) == .listening)
        #expect(face(.listening, busy: true) == .working)
        #expect(face(.hearing, busy: true) == .hearing)
        #expect(face(.speaking, busy: true) == .speaking)
        #expect(face(.degraded) == .degraded(.engineError))
        #expect(face(.degraded, reason: .loop) == .degraded(.loop))
        #expect(face(.listening, .connecting) == .connecting)
        #expect(face(.speaking, .reconnecting) == .connecting)
        #expect(face(.speaking, .ended) == .ended)
        #expect(face(.degraded, busy: true, .ended) == .ended)
    }

    @Test("Connecting sweeps, listening and working breathe, hearing is steady, degraded and ended hold still")
    func motion() {
        #expect(VoiceCallFace.connecting.motion == ActivityKind.connecting.icon.motion)
        #expect(VoiceCallFace.connecting.motion.isAnimated)
        for face in [VoiceCallFace.listening, .working, .speaking] {
            guard case .breath = face.motion else {
                Issue.record("\(face) does not breathe")
                continue
            }
        }
        #expect(VoiceCallFace.working.motion == ActivityMotion.working)
        #expect(VoiceCallFace.hearing.motion == .still)
        #expect(VoiceCallFace.degraded(.runaway).motion == .still)
        #expect(VoiceCallFace.ended.motion == .still)
    }

    @Test("Listening swells more slowly than work, so the two are told apart")
    func listeningIsSlower() {
        guard case .breath(let listening) = VoiceCallFace.listening.motion,
            case .breath(let working) = VoiceCallFace.working.motion
        else {
            Issue.record("both breathe")
            return
        }
        #expect(listening.period > working.period)
    }

    @Test("Tones: danger only for a degraded voice, quiet for the ends, live for the rest")
    func tones() {
        #expect(VoiceCallFace.degraded(.overload).tone == .danger)
        #expect(VoiceCallFace.ended.tone == .quiet)
        #expect(VoiceCallFace.connecting.tone == .quiet)
        for face in [VoiceCallFace.listening, .hearing, .speaking, .working] {
            #expect(face.tone == .live)
        }
    }

    @Test("Every face has a symbol, a one-column glyph, a word and a sentence, and every word is distinct")
    func identity() {
        for face in VoiceCallFace.everyFace {
            #expect(!face.symbol.isEmpty)
            #expect(face.glyph.count == 1, "\(face)")
            #expect(!face.word.isEmpty)
            #expect(!face.spoken.isEmpty)
        }
        #expect(Set(VoiceCallFace.everyFace.map(\.word)).count == VoiceCallFace.everyFace.count)
        #expect(Set(VoiceCallFace.everyFace.map(\.symbol)).count == VoiceCallFace.everyFace.count)
        #expect(VoiceCallFace.ended.isOpen == false)
        #expect(VoiceCallFace.listening.isOpen)
    }

    @Test("A degraded sentence carries the reason in words")
    func degradedSpoken() {
        for reason in [VoiceDegradedReason.runaway, .loop, .engineError, .engineDown, .overload] {
            let spoken = VoiceCallFace.degraded(reason).spoken
            #expect(spoken.contains(VoiceCallReading.degraded(reason)))
            #expect(VoiceCallReading.degraded(reason, recovering: true) != VoiceCallReading.degraded(reason))
        }
    }

    @Test("Speaking leans with the level, stays within 0...1 and holds steady under reduced motion")
    func speakingIntensity() {
        let quiet = VoiceCallFace.speaking.intensity(at: 0.7, level: 0)
        let loud = VoiceCallFace.speaking.intensity(at: 0.7, level: 1)
        #expect(loud > quiet)
        for step in 0..<40 {
            for level in [0.0, 0.5, 1.0, 3.0, -1.0] {
                let value = VoiceCallFace.speaking.intensity(at: Double(step) * 0.13, level: level)
                #expect(value >= ActivityTuning.breathFloor && value <= 1)
            }
        }
        #expect(VoiceCallFace.speaking.intensity(at: 0.4, level: 0.2, reduceMotion: true) == 1)
        #expect(VoiceCallFace.hearing.intensity(at: 0.4, level: 0.9) == 1)
        #expect(VoiceCallFace.degraded(.loop).intensity(at: 1.3) == 1)
    }

    @Test("A person is told, for every platform, how to get a microphone back")
    func microphone() {
        let lines = [VoiceClientKind.ios, .mac, .linux].map { VoiceCallReading.microphoneDenied(client: $0) }
        #expect(Set(lines).count == 3)
        #expect(lines.allSatisfy { $0.contains("cannot hear you") })
    }

    @Test("Every end of a call has a sentence of its own")
    func ends() {
        let ends: [VoiceCallEnd] = [
            .hungUp, .lost, .couldNotConnect("refused"), .microphoneDenied, .audioUnavailable("no device"),
            .gateway(code: "busy", message: ""), .gateway(code: "version", message: ""),
            .gateway(code: "engineDown", message: ""), .gateway(code: "silent", message: ""),
            .gateway(code: "hello", message: ""), .gateway(code: "odd", message: "Something odd."),
            .gateway(code: "odd", message: ""),
        ]
        let lines = ends.map { VoiceCallReading.end($0, client: .ios) }
        #expect(lines.allSatisfy { !$0.isEmpty })
        #expect(Set(lines).count == lines.count)
        #expect(lines[10].contains("Something odd."))
    }
}

@Suite("Voice call entry point")
struct VoiceCallEntryPointTests {
    private let reaches: [VoiceReach] = [
        .unknown, .checking, .ready(gateway: "0.1"), .loading, .busy, .noGateway, .tooOld(protocol: 0),
        .tooOld(protocol: 9), .engineDown(detail: nil), .engineDown(detail: "no GPU"), .wantsPassword,
        .unreachable("it did not answer in time"),
    ]

    @Test("The control shares the call's symbol and glyph with its beta card")
    func identity() {
        #expect(VoiceCallEntryPoint.symbol == BetaFeature.voiceCall.card.symbol)
        #expect(VoiceCallEntryPoint.glyph == BetaFeature.voiceCall.card.glyph)
        #expect(VoiceCallEntryPoint.title == BetaFeature.voiceCall.card.name)
        #expect(VoiceCallEntryPoint.label(active: false) == "Call")
        #expect(VoiceCallEntryPoint.label(active: true) == "Hang up")
    }

    @Test("Every reach says why in one line a person can act on, and the tooltip carries it")
    func reasons() {
        for reach in reaches {
            #expect(!reach.line.isEmpty)
            #expect(!reach.line.contains("\n"))
            let tooltip = VoiceCallEntryPoint.tooltip(reach: reach)
            #expect(!tooltip.isEmpty)
            if !reach.canStart { #expect(tooltip == reach.line) }
            let label = VoiceCallEntryPoint.accessibilityLabel(reach: reach, active: false)
            #expect(!label.isEmpty)
            if !reach.canStart { #expect(label.contains(reach.line)) }
        }
        #expect(Set(reaches.map(\.line)).count == reaches.count)
    }

    @Test("A call in progress is always ended with the same words, whatever the gateway says now")
    func active() {
        for reach in reaches {
            #expect(VoiceCallEntryPoint.isEnabled(reach: reach, active: true))
            #expect(VoiceCallEntryPoint.tooltip(reach: reach, active: true) == "Hang up the call")
            #expect(VoiceCallEntryPoint.accessibilityLabel(reach: reach, active: true) == "Hang up the call")
        }
    }

    @Test("The control is dimmed only where no press could help")
    func enabled() {
        #expect(VoiceCallEntryPoint.isEnabled(reach: .ready(gateway: "0.1")))
        #expect(VoiceCallEntryPoint.isEnabled(reach: .unknown))
        #expect(VoiceCallEntryPoint.isEnabled(reach: .wantsPassword))
        #expect(VoiceCallEntryPoint.isEnabled(reach: .unreachable("x")))
        for reach: VoiceReach in [.checking, .loading, .busy, .noGateway, .tooOld(protocol: 0), .engineDown(detail: nil)] {
            #expect(!VoiceCallEntryPoint.isEnabled(reach: reach))
        }
    }

    @Test("A gateway older than the app and one newer than it are told apart")
    func versions() {
        #expect(VoiceReach.tooOld(protocol: 0).line != VoiceReach.tooOld(protocol: 2).line)
    }

    @Test("Tones follow meaning: ready is live, waiting is attention, a dead end is danger")
    func tones() {
        #expect(VoiceReach.ready(gateway: "0.1").tone == .live)
        #expect(VoiceReach.loading.tone == .attention)
        #expect(VoiceReach.wantsPassword.tone == .attention)
        #expect(VoiceReach.noGateway.tone == .danger)
        #expect(VoiceReach.checking.tone == .quiet)
    }
}

@Suite("Voice call levels")
struct VoiceCallLevelsTests {
    @Test("A level rises faster than it falls")
    func attackAndRelease() {
        let up = VoiceCallLevels.smoothed(previous: 0, target: 1, dt: 0.05)
        let down = 1 - VoiceCallLevels.smoothed(previous: 1, target: 0, dt: 0.05)
        #expect(up > down)
        #expect(up > 0.5)
    }

    @Test("It heads for the target without passing it and settles on it")
    func converges() {
        var level = 0.0
        for _ in 0..<200 {
            level = VoiceCallLevels.smoothed(previous: level, target: 0.6, dt: 1.0 / 60)
            #expect(level <= 0.6 + 1e-9)
        }
        #expect(abs(level - 0.6) < 0.001)
        for _ in 0..<400 { level = VoiceCallLevels.smoothed(previous: level, target: 0, dt: 1.0 / 60) }
        #expect(level < 0.001)
    }

    @Test("No time passing changes nothing, and garbage is kept inside 0...1")
    func edges() {
        #expect(VoiceCallLevels.smoothed(previous: 0.3, target: 1, dt: 0) == 0.3)
        #expect(VoiceCallLevels.smoothed(previous: 0.3, target: 1, dt: -1) == 0.3)
        #expect(VoiceCallLevels.smoothed(previous: 5, target: 9, dt: 0.1) == 1)
        #expect(VoiceCallLevels.smoothed(previous: -2, target: -3, dt: 0.1) == 0)
        #expect(VoiceCallLevels.smoothed(previous: .nan, target: .infinity, dt: 0.1) == 0)
    }

    @Test("A long step lands on the target, and the same time in small steps lands where one big one does")
    func stepsAgree() {
        #expect(VoiceCallLevels.smoothed(previous: 0, target: 1, dt: 5) > 0.999)
        var small = 0.0
        for _ in 0..<10 { small = VoiceCallLevels.smoothed(previous: small, target: 1, dt: 0.01) }
        let big = VoiceCallLevels.smoothed(previous: 0, target: 1, dt: 0.1)
        #expect(abs(small - big) < 1e-9)
    }
}
