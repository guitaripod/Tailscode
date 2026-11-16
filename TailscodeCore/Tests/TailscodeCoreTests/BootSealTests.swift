import Foundation
import Testing

@testable import TailscodeCore

@Suite("Boot seal")
struct BootSealTests {
    private func evidence(
        available: Bool = false, servers: Bool = true, opens: Bool = true, preferences: Bool = true,
        canary: Bool = true
    ) -> BootSeal.Evidence {
        BootSeal.Evidence(
            protectedDataAvailable: available, serversFileExists: servers, serversFileOpens: opens,
            preferencesFileExists: preferences, canaryReadsBack: canary)
    }

    @Test("an unlocked phone is never sealed, whatever a read says")
    func unlocked() {
        #expect(!BootSeal.isSealed(evidence(available: true, opens: false, canary: false)))
        #expect(!BootSeal.isSealed(evidence(available: true)))
    }

    @Test("a phone locked after its first unlock reads everything and is not sealed")
    func lockedInAPocket() {
        #expect(!BootSeal.isSealed(evidence()))
        #expect(!BootSeal.isSealed(evidence(servers: false, opens: false)))
    }

    @Test("before the first unlock a saved file that will not open is a seal")
    func serversWillNotOpen() {
        #expect(BootSeal.isSealed(evidence(opens: false)))
        #expect(BootSeal.isSealed(evidence(opens: false, preferences: false, canary: false)))
    }

    @Test("so are preferences that exist and read back nothing")
    func preferencesReadEmpty() {
        #expect(BootSeal.isSealed(evidence(canary: false)))
        #expect(BootSeal.isSealed(evidence(servers: false, opens: false, canary: false)))
    }

    @Test("a first launch has nothing saved and is not sealed, locked or not")
    func firstLaunch() {
        #expect(!BootSeal.isSealed(evidence(servers: false, opens: false, preferences: false, canary: false)))
    }

    @Test("the canaries are the migration flag every launch has set and the seal's own")
    func canaries() {
        #expect(BootSeal.canaryKeys == ["tailscode.sharedStoreMigrated", "tailscode.bootSeal.opened"])
    }
}
