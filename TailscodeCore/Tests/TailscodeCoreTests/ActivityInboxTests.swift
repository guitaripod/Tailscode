import Foundation
import Testing

@testable import TailscodeCore

/// Every device-local store shares one `UserDefaults`, and corelibs' is not safe to write from two
/// threads at once — suites that exercise them have to be serialized against each other, not only
/// against themselves, or one suite's writes make another's reads flaky.
@Suite(.serialized)
struct DeviceStores {}

/// The list only earns its place if it cannot lie: no duplicates when a render repeats, nothing
/// left standing after the request it describes was answered, and nothing kept about a chat that
/// has actually been looked at.
extension DeviceStores {
  @Suite("Activity inbox")
  struct ActivityInboxTests {

    private func fresh() {
      UserDefaults.standard.removeObject(forKey: ActivityInbox.storageKey)
    }

    private func alert(
      _ identifier: String, session: String = "s1",
      reason: ActivityAlert.Reason = .turnEnded
    ) -> ActivityAlert {
      ActivityAlert(
        profileID: "p1", sessionID: session, identifier: identifier, title: "A chat",
        body: "Your agent finished.", reason: reason)
    }

    @Test("A repeated render adds nothing")
    func recordIsIdempotent() {
      fresh()
      ActivityInbox.record([alert("done:s1")])
      ActivityInbox.record([alert("done:s1")])
      #expect(ActivityInbox.count == 1)
    }

    @Test("The newest is the one at the top")
    func newestFirst() {
      fresh()
      ActivityInbox.record([alert("done:s1", session: "s1")])
      ActivityInbox.record([alert("done:s2", session: "s2")])
      #expect(ActivityInbox.all().first?.sessionID == "s2")
    }

    @Test("A request answered on the server leaves the list with its notification")
    func withdrawalRemoves() {
      fresh()
      ActivityInbox.record([alert("perm:1", reason: .needsApproval)])
      ActivityInbox.record([alert("done:s1")])
      ActivityInbox.withdraw(["perm:1"])
      #expect(ActivityInbox.all().map(\.identifier) == ["done:s1"])
    }

    @Test("Opening a chat clears that chat and only that chat")
    func clearIsPerSession() {
      fresh()
      ActivityInbox.record([alert("done:s1", session: "s1")])
      ActivityInbox.record([alert("done:s2", session: "s2")])
      ActivityInbox.clear(sessionID: "s1")
      #expect(ActivityInbox.all().map(\.sessionID) == ["s2"])
    }

    @Test("A day of a busy fleet cannot grow without bound")
    func capped() {
      fresh()
      for index in 0..<(ActivityInbox.limit + 20) {
        ActivityInbox.record([alert("done:\(index)", session: "s\(index)")])
      }
      #expect(ActivityInbox.count == ActivityInbox.limit)
    }

    @Test("Only a blocked turn is a turn still waiting on someone")
    func blockingIsTheRequests() {
      fresh()
      ActivityInbox.record([
        alert("done:s1"), alert("perm:1", reason: .needsApproval),
        alert("question:1", reason: .needsAnswer),
      ])
      let byIdentifier = Dictionary(
        uniqueKeysWithValues: ActivityInbox.all().map { ($0.identifier, $0.isBlocking) })
      #expect(byIdentifier["done:s1"] == false)
      #expect(byIdentifier["perm:1"] == true)
      #expect(byIdentifier["question:1"] == true)
      fresh()
    }
  }
}

/// The aura is one effect running on three toolkits, so the thing they share is its clock.
@Suite("Ultracode aura")
struct UltracodeAuraTests {

  @Test("The rainbow's head travels once round in one turn, and meets itself")
  func phaseWraps() {
    #expect(abs(Ultracode.aura(at: 0).phase) < 0.0001)
    #expect(abs(Ultracode.aura(at: Ultracode.auraTurnSeconds / 2).phase - 0.5) < 0.0001)
    let full = Ultracode.aura(at: Ultracode.auraTurnSeconds).phase
    #expect(full < 0.0001 || full > 0.9999)
  }

  @Test("The glow breathes between its floor and full, and never blinks out")
  func glowStaysLit() {
    var lowest = 1.0
    var highest = 0.0
    for step in 0..<400 {
      let glow = Ultracode.aura(at: Double(step) * 0.02).glow
      #expect(glow >= Ultracode.auraBreathFloor - 0.0001)
      #expect(glow <= 1.0001)
      lowest = min(lowest, glow)
      highest = max(highest, glow)
    }
    #expect(abs(lowest - Ultracode.auraBreathFloor) < 0.01)
    #expect(highest > 0.999)
  }

  @Test("A frame that never lands does not slow the turn down")
  func phaseIsClockBound() {
    let sparse = Ultracode.aura(at: 10).phase
    let dense = Ultracode.aura(at: 10).phase
    #expect(sparse == dense)
    #expect(Ultracode.aura(at: 1).phase != Ultracode.aura(at: 2).phase)
  }

  @Test("Turn and breath do not divide into each other, so they never lock into a beat")
  func periodsAreNotHarmonic() {
    let ratio = Ultracode.auraTurnSeconds / (Ultracode.auraBreathSeconds * 2)
    #expect(abs(ratio - ratio.rounded()) > 0.05)
  }
}
