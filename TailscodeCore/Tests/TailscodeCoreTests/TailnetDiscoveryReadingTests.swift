import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A phone's view of its tailnet hangs on a token that expires on its own. What these pin is that a
/// dead token is said once, in words, and never stops the machines the phone already knows from
/// being asked.
@Suite("Tailnet discovery reading")
struct TailnetDiscoveryReadingTests {
    private func device(_ host: String, os: String = "linux", lastSeenAgo: TimeInterval = 5, now: Date) -> TailscaleDevice {
        TailscaleDevice(
            name: "\(host).tail.ts.net", hostname: host, addresses: ["100.64.0.1"], os: os,
            lastSeen: now.addingTimeInterval(-lastSeenAgo).ISO8601Format())
    }

    @Test("off the tailnet the one thing to do is turn Tailscale on")
    func tailnetDown() {
        for key in [TailnetKey.none, .saved, .rejected] {
            let reading = TailnetDiscoveryReading.read(tailnetUp: false, key: key, remembered: 4)
            #expect(reading.primary == .openTailscale)
            #expect(!reading.canScan)
        }
    }

    @Test("a working token scans, and offers to be replaced")
    func savedKey() {
        let reading = TailnetDiscoveryReading.read(tailnetUp: true, key: .saved, remembered: 0)
        #expect(reading.primary == .scan)
        #expect(reading.secondary == .replaceKey)
        #expect(reading.canScan)
    }

    @Test("no token and no memory asks for a token")
    func nothingToGoOn() {
        let reading = TailnetDiscoveryReading.read(tailnetUp: true, key: .none, remembered: 0)
        #expect(reading.primary == .addKey)
        #expect(reading.secondary == nil)
        #expect(!reading.canScan)
    }

    @Test("remembered machines are asked without a token, and a token is still offered")
    func rememberedWithoutKey() {
        let reading = TailnetDiscoveryReading.read(tailnetUp: true, key: .none, remembered: 3)
        #expect(reading.primary == .scanRemembered)
        #expect(reading.secondary == .addKey)
        #expect(reading.headline.contains("3"))
    }

    @Test("a rejected token says so, and the remembered machines are still asked")
    func rejectedWithMemory() {
        let reading = TailnetDiscoveryReading.read(tailnetUp: true, key: .rejected, remembered: 2)
        #expect(reading.primary == .scanRemembered)
        #expect(reading.secondary == .replaceKey)
        #expect(reading.headline.contains("no longer accepts"))
    }

    @Test("a rejected token with nothing remembered can only be replaced")
    func rejectedWithoutMemory() {
        let reading = TailnetDiscoveryReading.read(tailnetUp: true, key: .rejected, remembered: 0)
        #expect(reading.primary == .replaceKey)
        #expect(reading.secondary == nil)
        #expect(!reading.canScan)
    }

    @Test("the replace button says new when the old token is dead and update when it is merely old")
    func replaceTitle() {
        #expect(TailnetDiscoveryReading.title(of: .replaceKey, key: .rejected) == "Add a new token")
        #expect(TailnetDiscoveryReading.title(of: .replaceKey, key: .saved) == "Update token")
    }

    @Test("the settings row names a dead token plainly")
    func settingsValue() {
        #expect(TailnetKey.none.settingsValue == "Not set")
        #expect(TailnetKey.saved.settingsValue == "Saved in Keychain")
        #expect(TailnetKey.rejected.settingsValue == "Stopped working — tap to replace")
    }

    @Test("a listing is remembered without its liveness, keeping only machines that can host an agent")
    func remembering() {
        let now = Date()
        let listing = [
            device("arch", now: now),
            device("phone", os: "iOS", now: now),
            device("asleep", lastSeenAgo: 3600 * 24, now: now),
        ]
        let memory = KnownMachines.remembering(listing, now: now)
        #expect(memory.devices.map(\.hostname) == ["arch"])
        #expect(memory.devices.allSatisfy { $0.lastSeen == nil && $0.connectedToControl == nil })
    }

    @Test("a remembered machine is scannable however long ago the scan was")
    func rememberedMachinesAreProbed() {
        let now = Date()
        let memory = KnownMachines.remembering([device("arch", now: now)], now: now)
        let later = now.addingTimeInterval(3600 * 24 * 10)
        #expect(TailnetScanner.scannableDevices(memory.devices(now: later), now: later).map(\.hostname) == ["arch"])
    }

    @Test("the memory goes stale after its age and is empty rather than wrong")
    func staleness() {
        let now = Date()
        let memory = KnownMachines.remembering([device("arch", now: now)], now: now)
        #expect(memory.devices(now: now.addingTimeInterval(KnownMachines.maxAge - 1)).count == 1)
        #expect(memory.devices(now: now.addingTimeInterval(KnownMachines.maxAge + 1)).isEmpty)
    }

    @Test("the memory survives being written and read back")
    func roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let memory = KnownMachines.remembering([device("arch", now: now)], now: now)
        let data = try JSONEncoder().encode(memory)
        #expect(try JSONDecoder().decode(KnownMachines.self, from: data) == memory)
    }
}
