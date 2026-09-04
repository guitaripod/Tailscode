import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A bookmark belongs to the conversation, so the server is the authority — except about a press
/// it has not been told about yet, which is the one thing this device knows and it does not.
extension DeviceStores {
  @Suite("Saved chat sync")
  struct SavedChatSyncTests {

    private func fresh() {
      SavedChatStore.forgetForTesting()
    }

    private func entry(_ id: String, saved: Bool?) -> SessionEntry {
      SessionEntry(
        profileID: "p1", profileName: "studio", host: "studio", backendType: .claudeCode,
        session: AgentSession(
          id: id, agentType: .claudeCode, title: "A chat", createdAt: .distantPast,
          updatedAt: Date(), saved: saved))
    }

    @Test("A bookmark made on another machine arrives with the listing")
    func adoptsServerTruth() {
      fresh()
      SavedChatStore.reconcile(with: [entry("s1", saved: true)])
      #expect(SavedChatStore.contains(profileID: "p1", sessionID: "s1"))
    }

    @Test("A bookmark dropped on another machine goes here too")
    func adoptsServerRemoval() {
      fresh()
      SavedChatStore.save(entry("s1", saved: nil))
      SavedChatStore.forget(profileID: "p1", sessionID: "s1")
      SavedChatStore.reconcile(with: [entry("s1", saved: false)])
      #expect(!SavedChatStore.contains(profileID: "p1", sessionID: "s1"))
    }

    @Test("A server with no notion of a bookmark says nothing about one")
    func silenceIsNotDenial() {
      fresh()
      SavedChatStore.save(entry("s1", saved: nil))
      SavedChatStore.forget(profileID: "p1", sessionID: "s1")
      SavedChatStore.reconcile(with: [entry("s1", saved: nil)])
      #expect(SavedChatStore.contains(profileID: "p1", sessionID: "s1"))
    }

    @Test("A press the server has not heard about outranks what the server says")
    func pendingOutranksTheListing() {
      fresh()
      SavedChatStore.save(entry("s1", saved: nil))
      SavedChatStore.reconcile(with: [entry("s1", saved: false)])
      #expect(SavedChatStore.contains(profileID: "p1", sessionID: "s1"))
      #expect(SavedChatStore.pending().map(\.sessionID) == ["s1"])
    }

    @Test("A delivered press is retired; an unreachable one waits")
    func drainRetiresWhatLanded() async {
      fresh()
      SavedChatStore.save(entry("s1", saved: nil))
      SavedChatStore.remove(profileID: "p1", sessionID: "s2")
      let delivered = await SavedChatSync.drain { intent in
        intent.sessionID == "s1" ? .delivered : .unreachable
      }
      #expect(delivered)
      #expect(SavedChatStore.pending().map(\.sessionID) == ["s2"])
    }

    @Test("A server that cannot keep bookmarks is not asked twice")
    func unsupportedRetiresUnsent() async {
      fresh()
      SavedChatStore.save(entry("s1", saved: nil))
      let delivered = await SavedChatSync.drain { _ in .unsupported }
      #expect(!delivered)
      #expect(SavedChatStore.pending().isEmpty)
      #expect(SavedChatStore.contains(profileID: "p1", sessionID: "s1"))
    }

    @Test("The last press is the one the server hears about")
    func lastPressWins() {
      fresh()
      SavedChatStore.save(entry("s1", saved: nil))
      SavedChatStore.remove(profileID: "p1", sessionID: "s1")
      #expect(SavedChatStore.pending().count == 1)
      #expect(SavedChatStore.pending().first?.saved == false)
    }
  }
}
