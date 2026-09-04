import CodingAgentKit
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
      ActivityInbox.forgetForTesting()
    }

    private func alert(
      _ identifier: String, session: String = "s1",
      reason: ActivityAlert.Reason = .turnEnded
    ) -> ActivityAlert {
      ActivityAlert(
        profileID: "p1", sessionID: session, identifier: identifier, title: "A chat",
        body: "Your agent finished.", reason: reason)
    }

    @Test("News about a chat that is working again is not news")
    func liveSessionsAreNotFiled() {
      fresh()
      ActivityInbox.record(
        [
          MissedActivity(
            identifier: "done:s1", profileID: "p1", sessionID: "s1", title: "A chat",
            body: "Your agent finished.", reason: .turnEnded),
          MissedActivity(
            identifier: "perm:1", profileID: "p1", sessionID: "s1", title: "A chat",
            body: "Needs approval", reason: .needsApproval),
          MissedActivity(
            identifier: "done:s2", profileID: "p1", sessionID: "s2", title: "Another",
            body: "Your agent finished.", reason: .turnEnded),
        ], liveSessionIDs: ["s1"])
      #expect(Set(ActivityInbox.all().map(\.identifier)) == ["perm:1", "done:s2"])
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

    @Test("What was cleared does not come back when the same notice is filed again")
    func clearingOutlastsTheNotice() {
      fresh()
      let raised = Date()
      ActivityInbox.record([alert("done:s1")], at: raised)
      ActivityInbox.clearAll(at: raised.addingTimeInterval(1))
      ActivityInbox.record([alert("done:s1")], at: raised)
      #expect(ActivityInbox.all().isEmpty)
    }

    @Test("Clearing one chat does not silence the next thing that happens in it")
    func clearingDoesNotSilenceLaterNews() {
      fresh()
      let raised = Date()
      ActivityInbox.record([alert("done:s1")], at: raised)
      ActivityInbox.clear(sessionID: "s1", at: raised.addingTimeInterval(1))
      ActivityInbox.record([alert("done:s1")], at: raised.addingTimeInterval(2))
      #expect(ActivityInbox.all().map(\.identifier) == ["done:s1"])
    }

    @Test("Clearing one chat says nothing about another")
    func clearingIsNotAGlobalSilence() {
      fresh()
      let raised = Date()
      ActivityInbox.record([alert("done:s1", session: "s1")], at: raised)
      ActivityInbox.clear(sessionID: "s1", at: raised.addingTimeInterval(1))
      ActivityInbox.record([alert("done:s2", session: "s2")], at: raised)
      #expect(ActivityInbox.all().map(\.sessionID) == ["s2"])
    }

    @Test("An answered request cannot be filed again from a notice still standing")
    func withdrawalOutlastsTheNotice() {
      fresh()
      let raised = Date()
      ActivityInbox.record([alert("perm:1", reason: .needsApproval)], at: raised)
      ActivityInbox.withdraw(["perm:1"], at: raised.addingTimeInterval(1))
      ActivityInbox.record([alert("perm:1", reason: .needsApproval)], at: raised)
      #expect(ActivityInbox.all().isEmpty)
    }

    @Test("A day of a busy fleet cannot grow without bound")
    func capped() {
      fresh()
      for index in 0..<(ActivityInbox.limit + 20) {
        ActivityInbox.record([alert("done:\(index)", session: "s\(index)")])
      }
      #expect(ActivityInbox.count == ActivityInbox.limit)
    }

    private func row(
      _ session: String, title: String, active: Bool = false, profile: String = "p1"
    ) -> ActivityObservation {
      ActivityObservation(
        profileID: profile, sessionID: session, title: title, isActive: active)
    }

    @Test("A notice raised before the server named the chat takes the name when it lands")
    func reconcileAdoptsTheRealName() {
      fresh()
      ActivityInbox.record([
        ActivityAlert(
          profileID: "p1", sessionID: "s1", identifier: "done:s1", title: "New chat",
          body: "Your agent finished.", reason: .turnEnded)
      ])
      ActivityInbox.reconcile(
        [row("s1", title: "Audit the parity manifests")], authoritativeProfileIDs: ["p1"])
      #expect(ActivityInbox.all().first?.title == "Audit the parity manifests")
    }

    @Test("A name the server has not written yet never overwrites one that was")
    func reconcileKeepsTheBetterName() {
      fresh()
      ActivityInbox.record([alert("done:s1")])
      ActivityInbox.reconcile([row("s1", title: "New chat")], authoritativeProfileIDs: ["p1"])
      #expect(ActivityInbox.all().first?.title == "A chat")
    }

    @Test("A chat that is gone from a server that answered goes with it")
    func reconcileDropsDeleted() {
      fresh()
      ActivityInbox.record([alert("done:s1", session: "s1"), alert("done:s2", session: "s2")])
      ActivityInbox.reconcile([row("s2", title: "Still here")], authoritativeProfileIDs: ["p1"])
      #expect(ActivityInbox.all().map(\.sessionID) == ["s2"])
    }

    @Test("A server that said nothing has not said its chats are gone")
    func silenceIsNotDeletion() {
      fresh()
      ActivityInbox.record([alert("done:s1")])
      ActivityInbox.reconcile([], authoritativeProfileIDs: [])
      #expect(ActivityInbox.count == 1)
      ActivityInbox.reconcile([row("other", title: "x", profile: "p2")], authoritativeProfileIDs: ["p2"])
      #expect(ActivityInbox.count == 1)
    }

    @Test("Finished is not news about a chat that is working again — a question still is")
    func reconcileDropsSupersededNews() {
      fresh()
      ActivityInbox.record([
        alert("done:s1", session: "s1"),
        alert("question:1", session: "s2", reason: .needsAnswer),
      ])
      ActivityInbox.reconcile(
        [row("s1", title: "A chat", active: true), row("s2", title: "A chat", active: true)],
        authoritativeProfileIDs: ["p1"])
      #expect(ActivityInbox.all().map(\.identifier) == ["question:1"])
    }

    @Test("A refresh that changes nothing changes nothing")
    func reconcileIsQuietWhenNothingMoved() {
      fresh()
      let entries = [
        MissedActivity(
          identifier: "done:s1", profileID: "p1", sessionID: "s1", title: "A chat",
          body: "b", reason: .turnEnded)
      ]
      #expect(
        ActivityInbox.reconciled(
          entries, rows: [row("s1", title: "A chat")], authoritative: ["p1"]) == nil)
      #expect(ActivityInbox.reconciled([], rows: [], authoritative: ["p1"]) == nil)
    }

    @Test("A notice about an unnamed chat is named by the words that started it")
    func nameFallsBackToThePrompt() {
      #expect(MissedActivity.name(title: "A chat", latestPrompt: "anything") == "A chat")
      #expect(
        MissedActivity.name(title: "New chat", latestPrompt: "Fix the parity gate")
          == "Fix the parity gate")
      #expect(MissedActivity.name(title: "", latestPrompt: "   ") == "New conversation")
      #expect(MissedActivity.name(title: "New chat", latestPrompt: nil) == "New conversation")
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

  private func state(
    _ prompts: [String], status: BackendStatus, assistant: String? = nil
  ) -> ConversationState {
    var messages = prompts.enumerated().map { index, text in
      ChatMessage(
        id: "u\(index)", role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "u\(index):0", kind: .text(text))],
        createdAt: Date(timeIntervalSince1970: Double(index)))
    }
    if let assistant {
      messages.append(
        ChatMessage(
          id: "a", role: .assistant, agentType: .claudeCode,
          parts: [MessagePart(id: "a:0", kind: .text(assistant))],
          createdAt: Date(timeIntervalSince1970: 100)))
    }
    return ConversationState(messages: messages, status: status, hasLoadedTranscript: true)
  }

  @Test("A turn summoned by word belongs to the conversation, not to whoever typed it")
  func runningTurnCarriesTheWord() {
    #expect(Ultracode.turnInvoked(state(["ultracode: audit this"], status: .running)))
    #expect(
      Ultracode.turnInvoked(
        state(["plain first", "now ULTRACODE it"], status: .running, assistant: "working")))
  }

  @Test("A word in a turn that already ended lights nothing")
  func settledTurnsAreQuiet() {
    #expect(!Ultracode.turnInvoked(state(["ultracode: audit this"], status: .idle)))
    #expect(!Ultracode.turnInvoked(state(["ultracode then", "plain now"], status: .running)))
    #expect(!Ultracode.turnInvoked(state([], status: .running)))
  }

  @Test("The client reads the word exactly as the server that ran it does")
  func agreesWithTheServer() {
    #expect(!Ultracode.turnInvoked(state(["the ultracoder wrote this"], status: .running)))
    #expect(Ultracode.invokes("ultracode: audit this"))
  }
}
