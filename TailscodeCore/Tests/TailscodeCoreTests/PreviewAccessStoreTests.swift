import Foundation
import Testing

@testable import TailscodeCore

@Suite("Preview access store", .serialized)
struct PreviewAccessStoreTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("Nothing is known until a Mac is remembered")
    func startsEmpty() throws {
        try withDefaults { defaults in
            #expect(PreviewAccessStore.all(defaults: defaults).isEmpty)
            #expect(PreviewAccessStore.access(host: "studio", defaults: defaults) == nil)
        }
    }

    @Test("A remembered Mac is found by its host")
    func remembers() throws {
        try withDefaults { defaults in
            PreviewAccessStore.remember(
                PreviewAccess(host: "studio", port: 4301, name: "Studio"), defaults: defaults)
            let found = PreviewAccessStore.access(host: "studio", defaults: defaults)
            #expect(found?.port == 4301)
            #expect(found?.label == "Studio")
            #expect(PreviewAccessStore.all(defaults: defaults).count == 1)
        }
    }

    @Test("Remembering a host again replaces it rather than listing it twice")
    func replacesByHost() throws {
        try withDefaults { defaults in
            PreviewAccessStore.remember(PreviewAccess(host: "studio", port: 4300), defaults: defaults)
            PreviewAccessStore.remember(PreviewAccess(host: "mini"), defaults: defaults)
            PreviewAccessStore.remember(
                PreviewAccess(host: "studio", port: 4400, name: "Studio"), defaults: defaults)
            let all = PreviewAccessStore.all(defaults: defaults)
            #expect(all.count == 2)
            #expect(all.map(\.host).sorted() == ["mini", "studio"])
            #expect(PreviewAccessStore.access(host: "studio", defaults: defaults)?.port == 4400)
        }
    }

    @Test("Forgetting a host leaves the others")
    func forgets() throws {
        try withDefaults { defaults in
            PreviewAccessStore.remember(PreviewAccess(host: "studio"), defaults: defaults)
            PreviewAccessStore.remember(PreviewAccess(host: "mini"), defaults: defaults)
            PreviewAccessStore.forget(host: "studio", defaults: defaults)
            #expect(PreviewAccessStore.all(defaults: defaults).map(\.host) == ["mini"])
            PreviewAccessStore.forget(host: "nobody", defaults: defaults)
            #expect(PreviewAccessStore.all(defaults: defaults).count == 1)
        }
    }

    @MainActor
    @Test("Every change tells whoever is listening")
    func postsDidChange() throws {
        try withDefaults { defaults in
            let counter = Counter()
            let token = NotificationCenter.default.addObserver(
                forName: PreviewAccessStore.didChange, object: nil, queue: nil
            ) { _ in counter.bump() }
            defer { NotificationCenter.default.removeObserver(token) }
            PreviewAccessStore.remember(PreviewAccess(host: "studio"), defaults: defaults)
            PreviewAccessStore.forget(host: "studio", defaults: defaults)
            #expect(counter.count == 2)
        }
    }

    @Test("A host keeps its password under its own key and says where it answers")
    func identity() {
        let access = PreviewAccess(host: "studio", port: 4301)
        #expect(access.id == "studio")
        #expect(access.secretKey == "preview.studio")
        #expect(access.address == "studio:4301")
        #expect(access.label == "studio")
        #expect(PreviewAccess(host: "studio", name: "Studio").label == "Studio")
    }

    @Test("Only a refused or password-seeking answer asks for a password")
    func reach() {
        #expect(PreviewReach.wantsPassword.asksForPassword)
        #expect(PreviewReach.refused.asksForPassword)
        #expect(!PreviewReach.unreachable("x").asksForPassword)
        #expect(!PreviewReach.answering(version: "1").asksForPassword)
        #expect(PreviewReach.answering(version: "1").isAnswering)
        #expect(!PreviewReach.checking.isAnswering)
    }
}
