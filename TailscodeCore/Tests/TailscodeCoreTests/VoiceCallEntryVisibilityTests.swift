import Testing

@testable import TailscodeCore

@Suite("Voice call entry visibility")
struct VoiceCallEntryVisibilityTests {
    @Test("A chat on a server with no gateway, or not yet heard from, does not carry the control")
    func hiddenWhereVoiceIsNotThere() {
        for reach in [VoiceReach.unknown, .checking, .noGateway] {
            #expect(!VoiceCallEntryPoint.isShown(reach: reach, active: false))
            #expect(VoiceCallEntryPoint.isShown(reach: reach, active: true))
        }
    }

    @Test("Every other reach shows the control, so a press can start a call or open the checklist")
    func shownWhereAPressHelps() {
        let reaches: [VoiceReach] = [
            .ready(gateway: "1"), .stopped(gateway: "1"), .needsSetup, .loading, .busy, .tooOld(protocol: 0),
            .engineDown(detail: nil), .wantsPassword, .unreachable("x"),
        ]
        for reach in reaches { #expect(VoiceCallEntryPoint.isShown(reach: reach, active: false)) }
    }
}
