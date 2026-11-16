import Foundation
import Testing

@testable import TailscodeCore

@Suite("A notice whose chat was read since it appeared comes down")
struct NoticeWithdrawalTests {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    @Test("Read after the notice takes it down; read before it, or never, leaves it")
    func stale() {
        let seen: [String: Date] = ["read-after": t0.addingTimeInterval(30), "read-before": t0.addingTimeInterval(-60)]
        let isUnread: (String, Date) -> Bool = { session, moment in
            guard let look = seen[session] else { return true }
            return moment.timeIntervalSince1970 > look.timeIntervalSince1970 + 1
        }
        let shown = [
            NoticeWithdrawal.Shown(identifier: "a", sessionID: "read-after", shownAt: t0),
            NoticeWithdrawal.Shown(identifier: "b", sessionID: "read-before", shownAt: t0),
            NoticeWithdrawal.Shown(identifier: "c", sessionID: "never", shownAt: t0),
            NoticeWithdrawal.Shown(identifier: "d", sessionID: "read-after", shownAt: t0.addingTimeInterval(29.5)),
            NoticeWithdrawal.Shown(identifier: "e", sessionID: "", shownAt: t0),
        ]
        #expect(NoticeWithdrawal.stale(shown, isUnread: isUnread) == ["a"], "a look in the same moment as the notice is not proof it was seen")
    }

    @Test("A bridge's silent push names the read chats; anything else in it is ignored")
    func push() {
        #expect(NoticeWithdrawal.sessions(inPush: ["withdraw": ["s1", "", 3, "s2"]]) == ["s1", "s2"])
        #expect(NoticeWithdrawal.sessions(inPush: ["usage": ["x": 1]]).isEmpty)
    }
}
