import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quick ask", .serialized)
struct QuickAskTests {

    private func withCleanStore(_ body: () -> Void) {
        let key = "tailscode.quickask.server"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        body()
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test("The last quick ask's server answers the next one")
    func lastServerWins() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "two")
            #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: "one") == "two")
        }
    }

    @Test("A remembered server that left the fleet falls back")
    func staleMemoryFallsBack() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "gone")
            #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: "two") == "two")
        }
    }

    @Test("No memory and no fallback still aims at a server")
    func firstServerAsLastResort() {
        withCleanStore {
            #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: nil) == "one")
            #expect(QuickAskDefaults.target(among: ["one"], fallback: "absent") == "one")
        }
    }

    @Test("No servers means no target — the surface's cue to offer setup")
    func emptyFleetIsNil() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "one")
            #expect(QuickAskDefaults.target(among: [], fallback: nil) == nil)
        }
    }

    @Test("Clearing forgets the memory")
    func clearForgets() {
        withCleanStore {
            QuickAskDefaults.record(profileID: "one")
            QuickAskDefaults.clear()
            #expect(QuickAskDefaults.lastProfileID == nil)
        }
    }
}
