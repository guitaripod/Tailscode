import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Row age clock")
struct RowAgeClockTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func entry(updated: Date) -> SessionEntry {
        SessionEntry(
            profileID: "one", profileName: "arch", host: "arch", backendType: .claudeCode,
            session: AgentSession(
                id: "s1", agentType: .claudeCode, title: "chat", directory: "/tmp/one",
                createdAt: updated, updatedAt: updated, isActive: true))
    }

    @Test("A reachable server's row ages against this device's clock")
    func reachableRowAges() {
        let row = SessionRowModel(
            entry: entry(updated: Date().addingTimeInterval(-90)), unreachable: false,
            unread: false, saved: false)
        #expect(row.age == "1m")
        #expect(row.state == .live)
    }

    @Test("An unreachable server's row freezes at the last reading instead of ageing")
    func unreachableRowFreezes() {
        let updated = epoch
        let observed = epoch.addingTimeInterval(30)
        let row = SessionRowModel(
            entry: entry(updated: updated), unreachable: true, unread: false, saved: false,
            observedAt: observed)
        #expect(row.age == "30s")
        #expect(row.state == .offline)
    }

    @Test("A frozen row reads the same however long the server stays away")
    func frozenRowIsStable() {
        let observed = epoch.addingTimeInterval(45)
        func draw() -> String {
            SessionRowModel(
                entry: entry(updated: epoch), unreachable: true, unread: false, saved: false,
                observedAt: observed
            ).age
        }
        #expect(draw() == draw())
        #expect(draw() == "45s")
    }

    @Test("An unreachable server never heard from falls back to this device's clock")
    func unreachableWithNoReadingUsesNow() {
        let row = SessionRowModel(
            entry: entry(updated: Date().addingTimeInterval(-120)), unreachable: true,
            unread: false, saved: false)
        #expect(row.age == "2m")
    }

    @Test("Clock skew clamps at zero rather than counting backwards")
    func skewClamps() {
        #expect(SessionRowModel.age(of: epoch.addingTimeInterval(5), asOf: epoch) == "0s")
    }

    @Test("The age column scales from seconds to days")
    func scales() {
        #expect(SessionRowModel.age(of: epoch, asOf: epoch.addingTimeInterval(9)) == "9s")
        #expect(SessionRowModel.age(of: epoch, asOf: epoch.addingTimeInterval(600)) == "10m")
        #expect(SessionRowModel.age(of: epoch, asOf: epoch.addingTimeInterval(7_200)) == "2h")
        #expect(SessionRowModel.age(of: epoch, asOf: epoch.addingTimeInterval(172_800)) == "2d")
    }
}
