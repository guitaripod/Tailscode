import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// What a person decides about a conversation is the server's to keep, so that a chat pinned from
/// the couch is pinned at the desk — and a press made with no server in reach is neither lost nor
/// overruled by the listing that lands before it has been told.
extension DeviceStores {
  @Suite("Session marks")
  struct SessionMarksTests {

    private func fresh() {
      let defaults = UserDefaults.standard
      for key in [
        SessionPinStore.storageKey, SessionPinStore.stampsKey, ArchivedChatStore.storageKey,
        SessionSeenStore.seenKey, SessionSeenStore.baselineKey,
      ] {
        defaults.removeObject(forKey: key)
      }
      SavedChatStore.forgetForTesting()
      MarkIntentStore.forgetAllForTesting()
      SessionOwners.forgetAllForTesting()
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
      _ id: String, profile: String = "p1", pinned: Bool? = nil, pinnedAt: TimeInterval? = nil,
      archived: Bool? = nil, readAt: TimeInterval? = nil, saved: Bool? = nil
    ) -> SessionEntry {
      SessionEntry(
        profileID: profile, profileName: "studio", host: "studio", backendType: .claudeCode,
        session: AgentSession(
          id: id, agentType: .claudeCode, title: "A chat", createdAt: Date(timeIntervalSince1970: 1),
          updatedAt: epoch, saved: saved, pinned: pinned,
          pinnedAt: pinnedAt.map { Date(timeIntervalSince1970: $0) }, archived: archived,
          readAt: readAt.map { Date(timeIntervalSince1970: $0) }))
    }

    @Test("A pin made on another device arrives, in the order it was made")
    func pinsArriveInOrder() {
      fresh()
      SessionMarks.reconcile(with: [
        entry("b", pinned: true, pinnedAt: 200, archived: false),
        entry("a", pinned: true, pinnedAt: 100, archived: false),
        entry("c", pinned: false, archived: false),
      ])
      #expect(SessionPinStore.all() == ["p1/a", "p1/b"])
    }

    @Test("A pin dropped on another device goes here too")
    func unpinTravels() {
      fresh()
      SessionPinStore.toggle(profileID: "p1", sessionID: "a")
      MarkIntentStore.forgetAllForTesting()
      SessionMarks.reconcile(with: [entry("a", pinned: false, archived: false)])
      #expect(SessionPinStore.all().isEmpty)
    }

    @Test("A press the server has not heard about outranks what the listing says")
    func pendingPinOutranksTheListing() {
      fresh()
      SessionPinStore.toggle(profileID: "p1", sessionID: "a")
      SessionMarks.reconcile(with: [entry("a", pinned: false, archived: false)])
      #expect(SessionPinStore.contains(profileID: "p1", sessionID: "a"))
      #expect(MarkIntentStore.holding(.pinned) == ["a"])
    }

    @Test("A server that says nothing about pins leaves them where they are")
    func silenceIsNotDenial() {
      fresh()
      SessionPinStore.toggle(profileID: "p1", sessionID: "a")
      MarkIntentStore.forgetAllForTesting()
      SessionMarks.reconcile(with: [entry("a")])
      #expect(SessionPinStore.contains(profileID: "p1", sessionID: "a"))
    }

    @Test("Archiving travels both ways, and a pending press holds")
    func archiveTravels() {
      fresh()
      SessionMarks.reconcile(with: [
        entry("a", pinned: false, archived: true), entry("b", pinned: false, archived: false),
      ])
      #expect(ArchivedChatStore.contains(profileID: "p1", sessionID: "a"))
      ArchivedChatStore.toggle(profileID: "p1", sessionID: "b")
      SessionMarks.reconcile(with: [
        entry("a", pinned: false, archived: false), entry("b", pinned: false, archived: false),
      ])
      #expect(!ArchivedChatStore.contains(profileID: "p1", sessionID: "a"))
      #expect(ArchivedChatStore.contains(profileID: "p1", sessionID: "b"))
    }

    @Test("A chat read on another device reads here, in the server's own clock")
    func readsArrive() {
      fresh()
      let updated = epoch.timeIntervalSince1970
      SessionMarks.reconcile(with: [
        entry("a", pinned: false, archived: false, readAt: updated + 5)
      ])
      let unread = SessionSeenStore.unreadEvaluator()
      #expect(!unread("a", epoch))
      #expect(unread("a", epoch.addingTimeInterval(60)))
    }

    @Test("A chat set aside as unread elsewhere is unread here")
    func unreadArrives() {
      fresh()
      SessionSeenStore.markSeen("a")
      MarkIntentStore.forgetAllForTesting()
      SessionMarks.reconcile(with: [
        entry("a", pinned: false, archived: false, readAt: epoch.timeIntervalSince1970 - 2)
      ])
      #expect(SessionSeenStore.unreadEvaluator()("a", epoch))
    }

    @Test("A read press waits for the server and outranks the listing until delivered")
    func pendingReadOutranks() {
      fresh()
      SessionSeenStore.markSeen("a")
      let mine = SessionSeenStore.values()["a"]
      SessionMarks.reconcile(with: [
        entry("a", pinned: false, archived: false, readAt: epoch.timeIntervalSince1970 - 2)
      ])
      #expect(SessionSeenStore.values()["a"] == mine)
      #expect(MarkIntentStore.holding(.read) == ["a"])
    }

    @Test("A listing teaches which server a conversation lives on")
    func ownersAreLearned() {
      fresh()
      SessionMarks.reconcile(with: [entry("a", profile: "p9", pinned: false, archived: false)])
      #expect(SessionOwners.profile(of: "a") == "p9")
    }

    @Test("A newer press replaces an older one about the same mark")
    func lastPressWins() {
      fresh()
      MarkIntentStore.note(sessionID: "a", mark: .pinned, on: true, at: epoch)
      MarkIntentStore.note(sessionID: "a", mark: .pinned, on: false, at: epoch.addingTimeInterval(1))
      MarkIntentStore.note(sessionID: "a", mark: .archived, on: true, at: epoch)
      let all = MarkIntentStore.all()
      #expect(all.count == 2)
      #expect(all.first { $0.mark == .pinned }?.on == false)
    }

    @Test("Retiring a delivered press never retires the newer press that replaced it")
    func forgetIsAboutThatPressOnly() {
      fresh()
      MarkIntentStore.note(sessionID: "a", mark: .read, on: true, at: epoch)
      let sent = MarkIntentStore.all()[0]
      MarkIntentStore.note(sessionID: "a", mark: .read, on: false, at: epoch.addingTimeInterval(5))
      MarkIntentStore.forget(sent)
      #expect(MarkIntentStore.all().map(\.on) == [false])
    }

    @Test("A delivered press is retired, an unreachable one waits, in the order they were made")
    func drainDelivers() async {
      fresh()
      MarkIntentStore.note(sessionID: "late", mark: .pinned, on: true, at: epoch.addingTimeInterval(9))
      MarkIntentStore.note(sessionID: "early", mark: .archived, on: true, at: epoch)
      MarkIntentStore.note(sessionID: "down", mark: .read, on: true, at: epoch.addingTimeInterval(4))
      let order = Order()
      let delivered = await SessionMarkSync.drain { intent in
        await order.add(intent.sessionID)
        return intent.sessionID == "down" ? .unreachable : .delivered
      }
      #expect(delivered)
      #expect(await order.items == ["early", "down", "late"])
      #expect(MarkIntentStore.all().map(\.sessionID) == ["down"])
    }

    @Test("A server that keeps no marks is not asked twice")
    func unsupportedRetiresUnsent() async {
      fresh()
      MarkIntentStore.note(sessionID: "a", profileID: "p1", mark: .pinned, on: true)
      let delivered = await SessionMarkSync.drain { _ in .unsupported }
      #expect(!delivered)
      #expect(MarkIntentStore.all().isEmpty)
    }

    @Test("A press whose server is not known yet waits for a listing to say")
    func unknownOwnerWaits() async {
      fresh()
      SessionSeenStore.markSeen("a")
      let delivered = await SessionMarkSync.drain(backendFor: { _ in nil })
      #expect(!delivered)
      #expect(MarkIntentStore.holding(.read) == ["a"])
      SessionOwners.remember([entry("a", profile: "gone")])
      _ = await SessionMarkSync.drain(backendFor: { _ in nil })
      #expect(MarkIntentStore.all().isEmpty)
    }

    @Test("Pins sort by when they were pinned; unstamped pins keep the place they were made in")
    func pinArithmetic() {
      let plan = MarkReconcile.pins(
        current: ["x", "y"], stamps: [:],
        reports: [
          MarkReconcile.PinReport(key: "n", sessionID: "n", pinned: true, at: 50),
          MarkReconcile.PinReport(key: "o", sessionID: "o", pinned: true, at: 10),
        ], held: [], now: 1_000)
      #expect(plan?.order == ["x", "y", "o", "n"])
      #expect(plan?.stamps["o"] == 10)
    }

    @Test("A listing that agrees with the device changes nothing")
    func agreementIsSilent() {
      let plan = MarkReconcile.pins(
        current: ["a"], stamps: ["a": 5],
        reports: [MarkReconcile.PinReport(key: "a", sessionID: "a", pinned: true, at: 5)],
        held: [], now: 1_000)
      #expect(plan == nil)
      #expect(
        MarkReconcile.reads(local: ["a": 10], reports: [("a", 10.3)], held: []).isEmpty)
    }
  }
}

private actor Order {
  var items: [String] = []
  func add(_ item: String) { items.append(item) }
}
