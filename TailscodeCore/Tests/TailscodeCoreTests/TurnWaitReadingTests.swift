import Foundation
import Testing

@testable import TailscodeCore

/// This device is the one holding the wait, so the words pin exactly what it can promise and
/// nothing more: a server that supports the route, a product name in the sentence when it does
/// not, opencode's generation gap said as a fact rather than a fault, and the device-wide notes
/// that govern every server at once kept separate from any one server's own answer.
@Suite("Turn wait reading")
struct TurnWaitReadingTests {
    @Test("a server that waits says so without naming any route or status code")
    func waits() {
        #expect(TurnWaitAvailability.waits.sentence == "Tells this iPhone when a turn ends, straight over your tailnet.")
        #expect(TurnWaitAvailability.waits.canWait)
    }

    @Test("an old server names the product to update, never a version number or a route")
    func serverTooOld() {
        let claude = TurnWaitAvailability.serverTooOld(product: "claude-bridge")
        #expect(claude.sentence == "Update claude-bridge to be told when a turn ends while Tailscode is closed.")
        #expect(!claude.canWait)

        let omp = TurnWaitAvailability.serverTooOld(product: "omp-bridge")
        #expect(omp.sentence == "Update omp-bridge to be told when a turn ends while Tailscode is closed.")
    }

    @Test("opencode 1.x reads as a generation gap, not blame")
    func openCodeGeneration() {
        let reading = TurnWaitAvailability.openCodeGeneration
        #expect(reading.sentence == "opencode 1.x can't be waited on. opencode 2 can.")
        #expect(!reading.canWait)
    }

    @Test("an unasked server says it hasn't been checked, never guesses")
    func unknown() {
        let reading = TurnWaitAvailability.unknown
        #expect(reading.sentence == "Tailscode hasn't checked yet whether this server can be waited on.")
        #expect(!reading.canWait)
    }

    @Test("every state but waits refuses to arm")
    func onlyWaitsCanWait() {
        let all: [TurnWaitAvailability] = [
            .waits, .serverTooOld(product: "claude-bridge"), .openCodeGeneration, .unknown,
        ]
        #expect(all.filter(\.canWait) == [.waits])
    }

    @Test("Background App Refresh being off is a device fact, worded and actioned separately from any server")
    func backgroundWakeDenied() {
        #expect(
            BackgroundWakeReading.deniedLine
                == "Background App Refresh is off for Tailscode, so a turn that ends while it's closed stays silent until you open it."
        )
        #expect(BackgroundWakeReading.openSettingsAction == "Open Settings")
    }

    @Test("the force-quit and privacy notes are standing facts about the mechanism, not warnings")
    func footers() {
        #expect(TurnWaitFooters.forceQuit == "Swiping Tailscode away stops the wait until you open it again.")
        #expect(
            TurnWaitFooters.privacy
                == "Tailscode waits on your servers directly. Nothing passes through Midgar or Apple.")
    }
}
