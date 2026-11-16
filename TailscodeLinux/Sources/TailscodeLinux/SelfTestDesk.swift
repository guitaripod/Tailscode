import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Quiet at the desk, from this computer's side: the phone's wishes and the muted names are
    /// kept like every other rule, the session answers for idle and lock without hanging, and a
    /// beat reads the desk and says plainly when no server keeps desks.
    static func checkDesk() throws -> Int {
        var claims = 0
        func expect(_ condition: Bool, _ claim: String) throws {
            guard condition else { throw SelfTestFailure("desk: \(claim)") }
            claims += 1
        }
        let kept = Notifier.rules
        defer { Notifier.setRules(kept) }
        Notifier.setRules(NoticeRules())
        Notifier.toggleMute("selftest-desk-chat", name: "Fix the queue")
        try expect(
            Notifier.rules.mutedChats.first?.name == "Fix the queue",
            "a chat muted from its menu keeps the name it had")
        try expect(
            (SettingsFile.stored(forKey: NoticeRulesKeys.mutedNames) as? [String: String])?["selftest-desk-chat"]
                == "Fix the queue", "in the settings file")
        Notifier.unmute("selftest-desk-chat")
        try expect(Notifier.rules.mutedNames.isEmpty, "and unmuting forgets it")
        Notifier.setDeskRules(quiet: false, awayAfter: 300)
        try expect(
            !Notifier.rules.quietAtDesk && Notifier.rules.awayAfter == 300,
            "the phone's wishes read back as they were written")

        let started = Date()
        let reading = DeskSense.reading()
        try expect(Date().timeIntervalSince(started) < 3, "asking the session for idle and lock never hangs")
        try expect(reading.idle.map { $0 >= 0 } ?? true, "and an idle it does give is a duration")

        let servers = try runBlocking { await DeskSense.servers().count }
        try expect(servers >= 0, "the servers this computer holds are found without hanging")
        let beat = DeskBeat(
            desk: "selftest-desk", name: "selftest", enabled: true, interval: 3600,
            sense: { DeskReading(idle: 7, locked: false) }, servers: { [] })
        let status = try runBlocking { () async -> DeskBeat.Status in
            await beat.look("selftest-chat")
            await beat.report()
            return await beat.status
        }
        try expect(status.reading == DeskReading(idle: 7, locked: false), "a beat reads the desk")
        try expect(
            status.asked == 0 && NoticeRulesWords.deskReportStatus(status).contains("Update"),
            "and with no server that keeps desks the page says what to update")
        try expect(
            NoticeRulesWords.deskReportStatus(DeskBeat.Status(enabled: true, reading: DeskReading(idle: 7), heard: 1, asked: 1))
                == "Telling one machine you’re here", "while one that does is named")
        let off = try runBlocking { () async -> DeskBeat.Status in
            await beat.setEnabled(false)
            return await beat.status
        }
        try expect(!off.enabled, "switched off it says nothing more")
        return claims
    }
}
