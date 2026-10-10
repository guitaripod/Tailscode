import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Runs only against a real bridge, on a scratch home that holds throwaway chats:
/// `TAILSCODE_LIVE_BRIDGE=http://127.0.0.1:14199 TAILSCODE_LIVE_PASSWORD=scratch swift test --filter LiveSessionMarksTests`.
/// This device is the stores; "another device" is a second backend talking to the same bridge.
extension DeviceStores {
  @Suite("Live session marks")
  struct LiveSessionMarksTests {
    private static func backend() -> (any CodingAgentBackend)? {
      let env = ProcessInfo.processInfo.environment
      guard let url = env["TAILSCODE_LIVE_BRIDGE"].flatMap(URL.init(string:)),
        let password = env["TAILSCODE_LIVE_PASSWORD"]
      else { return nil }
      return ClaudeCodeBackend(
        config: ServerConfig(
          baseURL: url, credentials: BasicCredentials(username: "claude", password: password)))
    }

    private func clean() {
      let defaults = UserDefaults.standard
      for key in [
        SessionPinStore.storageKey, SessionPinStore.stampsKey, ArchivedChatStore.storageKey,
        SessionSeenStore.seenKey,
      ] {
        defaults.removeObject(forKey: key)
      }
      SavedChatStore.forgetForTesting()
      MarkIntentStore.forgetAllForTesting()
      SessionOwners.forgetAllForTesting()
    }

    private func entries(_ backend: any CodingAgentBackend) async throws -> [SessionEntry] {
      try await backend.listSessions().map {
        SessionEntry(
          profileID: "live", profileName: "scratch", host: "127.0.0.1", backendType: .claudeCode,
          session: $0)
      }
    }

    @Test("A mark made elsewhere reaches this device through the stream, and one made here reaches elsewhere")
    func roundTrip() async throws {
      guard let other = Self.backend(), let mine = Self.backend() else { return }
      clean()
      let listing = try await entries(mine)
      let target = try #require(listing.first?.session.id)
      #expect(listing.allSatisfy { $0.session.reportsMarks })

      let changes = try #require(
        await (mine as? SessionListStreaming)?.sessionListChanges())
      let arrival = Task { () -> AgentSession? in
        for await change in changes {
          if case .upsert(let session) = change, session.id == target, session.pinned == true {
            return session
          }
        }
        return nil
      }
      try await other.setSessionMarks(target, SessionMarkChange(pinned: true))
      let pinned = try await withDeadline(seconds: 6) { await arrival.value }
      #expect(pinned?.pinnedAt != nil)
      let entry = SessionEntry(
        profileID: "live", profileName: "scratch", host: "127.0.0.1", backendType: .claudeCode,
        session: try #require(pinned))
      SessionMarks.reconcile(with: [entry])
      #expect(SessionPinStore.contains(profileID: "live", sessionID: target))

      SessionSeenStore.markUnread(target, updatedAt: listing[0].session.updatedAt)
      let delivered = await SessionMarkSync.drain(backendFor: { _ in mine })
      #expect(delivered)
      try await Task.sleep(for: .milliseconds(1600))
      let after = try await other.listSessions().first { $0.id == target }
      let readAt = try #require(after?.readAt)
      #expect(readAt < listing[0].session.updatedAt)

      SessionSeenStore.markSeen(target)
      _ = await SessionMarkSync.drain(backendFor: { _ in mine })
      try await Task.sleep(for: .milliseconds(1600))
      let seen = try await other.listSessions().first { $0.id == target }
      #expect((seen?.readAt ?? .distantPast) >= listing[0].session.updatedAt)

      try await other.setSessionMarks(target, SessionMarkChange(pinned: false))
      clean()
    }

    @Test("An older decision delivered late does not overrule a newer one")
    func lateDeliveryLoses() async throws {
      guard let backend = Self.backend() else { return }
      let listing = try await backend.listSessions()
      let target = try #require(listing.last?.id)
      let now = Date()
      try await backend.setSessionMarks(
        target, SessionMarkChange(archived: true, at: now))
      try await backend.setSessionMarks(
        target, SessionMarkChange(archived: false, at: now.addingTimeInterval(-60)))
      try await Task.sleep(for: .milliseconds(1600))
      let held = try await backend.listSessions().first { $0.id == target }
      #expect(held?.archived == true)
      try await backend.setSessionMarks(
        target, SessionMarkChange(archived: false, at: now.addingTimeInterval(1)))
    }

    private func withDeadline<T: Sendable>(
      seconds: Double, _ work: @escaping @Sendable () async -> T?
    ) async throws -> T? {
      try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
          try await Task.sleep(for: .seconds(seconds))
          return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }
  }
}
