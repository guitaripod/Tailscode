import AgentTestSupport
import AppKit
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Quiet at the desk, from this Mac's side: a muted chat keeps its name and the Notifications
    /// page lists it with its own Unmute, following the rules while it is open; the session
    /// answers for input and lock at once; and a beat tells a server that keeps desks who is here,
    /// which chat they had in front of them, and that the desk is leaving when it is switched off.
    static func checkDesk() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            checks += 1
            if !condition { throw SelfTestFailure("desk: \(label)") }
        }
        let kept = MacNotifier.rules
        defer { MacNotifier.setRules(kept) }
        MacNotifier.setRules(NoticeRules())
        MacNotifier.toggleMute("selftest-desk-a", name: "Fix the queue")
        MacNotifier.toggleMute("selftest-desk-b", name: "Ship the release")
        try expect(
            MacNotifier.rules.mutedChats.map(\.name) == ["Fix the queue", "Ship the release"],
            "a chat muted from its menu keeps the name it had")

        let preferences = PreferencesWindow(
            onComposerChanged: {}, onTranscriptChanged: {}, onReloadShortcuts: {})
        preferences.install(selecting: PreferencesWindow.page(named: "notifications"))
        preferences.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(
            preferences.mutedChats.arrangedSubviews.count == 3,
            "the page lists each muted chat and Unmute All: \(preferences.mutedChats.arrangedSubviews.count)")
        try expect(
            preferences.noticeSummary.stringValue.hasSuffix("2 chats muted"),
            "the summary counts them: \(preferences.noticeSummary.stringValue)")
        let unmute = NSButton()
        unmute.identifier = NSUserInterfaceItemIdentifier("selftest-desk-a")
        preferences.unmuteChat(unmute)
        try? await Task.sleep(for: .milliseconds(80))
        try expect(!MacNotifier.isMuted("selftest-desk-a"), "a row's Unmute unmutes that chat")
        try expect(MacNotifier.rules.mutedNames["selftest-desk-a"] == nil, "and forgets its name")
        try expect(
            preferences.mutedChats.arrangedSubviews.count == 1,
            "the open page follows: \(preferences.mutedChats.arrangedSubviews.count)")
        preferences.window?.close()

        let started = Date()
        let reading = MacDeskSense.reading()
        try expect(Date().timeIntervalSince(started) < 1, "asking the session for input and lock is immediate")
        try expect(reading.idle.map { $0 >= 0 } ?? true, "and an idle it gives is a duration")

        let keeper = MockBackend(deskPresence: DeskPresence())
        let beat = DeskBeat(
            desk: "selftest-desk", name: "selftest", enabled: true, interval: 3600,
            sense: { DeskReading(idle: 7) }, servers: { [DeskServer(key: "keeper", backend: keeper)] })
        await beat.look("selftest-chat")
        await beat.report()
        await beat.setEnabled(false)
        let reports = keeper.reportedDesks
        try expect(reports.first?.idle == 7 && reports.first?.name == "selftest", "a beat says who is here")
        try expect(reports.first?.looked == ["selftest-chat"], "and which chat they had in front of them")
        try expect(reports.last?.leaving == true, "switching it off is the desk's last word")
        try expect(
            NoticeRulesWords.deskReportStatus(await beat.status).hasPrefix("Off"),
            "after which the page says it is off")
        return checks
    }
}
