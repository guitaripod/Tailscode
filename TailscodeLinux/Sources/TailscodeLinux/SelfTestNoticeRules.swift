import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The person's notification rules live in the settings file and reach the watch: a choice
    /// survives a reinstall, the old switch still reads, a muted chat is muted, and finished work
    /// that went on in the background is one notice at the end rather than one per turn.
    static func checkNoticeRules() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ claim: String) throws {
            guard condition else { throw SelfTestFailure("notice rules: \(claim)") }
            claims += 1
        }
        let kept = Notifier.rules
        defer { Notifier.setRules(kept) }
        let chosen = NoticeRules(finish: .failures, minimumWork: 120, needsYou: false, muted: ["selftest-chat"])
        Notifier.setRules(chosen)
        try expect(Notifier.rules == chosen, "a choice reads back as it was made")
        try expect(
            (SettingsFile.stored(forKey: NoticeRulesKeys.finish) as? String) == "failures",
            "and is written to the settings file, which outlives a reinstall")
        try expect(
            (SettingsFile.stored(forKey: NoticeRulesKeys.legacyTurnComplete) as? Bool) == true,
            "while the old switch still says finished work is not switched off")
        try expect(!Notifier.notifyNeedsYou, "approvals follow their own switch")
        Notifier.toggleMute("selftest-chat")
        try expect(!Notifier.isMuted("selftest-chat"), "a muted chat unmutes from its menu")
        Notifier.toggleMute("selftest-chat")
        try expect(Notifier.isMuted("selftest-chat"), "and mutes again")

        var watch = ActivityWatch(rules: .standard)
        let start = Date(timeIntervalSince1970: 3_000_000)
        func state(_ status: BackendStatus, background: Int = 0) -> ConversationState {
            var state = ConversationState(status: status, connection: .live, hasLoadedTranscript: true)
            if background > 0 { state.backgroundWork = BackgroundWork(tasks: background) }
            return state
        }
        func observe(_ status: BackendStatus, _ seconds: TimeInterval, background: Int = 0) -> Int {
            watch.observeConversation(
                profileID: "p", sessionID: "s", title: "Self-test", state: state(status, background: background),
                at: start.addingTimeInterval(seconds)
            ).alerts.count
        }
        _ = observe(.idle, 0)
        _ = observe(.running, 1)
        try expect(observe(.idle, 60, background: 2) == 0, "a turn that hands over to background work says nothing")
        try expect(watch.due(at: start.addingTimeInterval(900)).isEmpty, "nor while that work runs")
        _ = observe(.running, 1200)
        _ = observe(.idle, 1260)
        try expect(
            watch.due(at: start.addingTimeInterval(1260 + WorkSettle.grace)).count == 1,
            "and the end of the work is one notice")
        return claims
    }
}
