import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A store changes wherever its caller is, and its observers are methods on main-actor types.
extension DeviceStores {
    @Suite("Store notices") struct StoreNoticeTests {
        private static let name = Notification.Name("tailscode.test.storeNotice")

        #if canImport(Darwin)
            @MainActor
            @Test("A notice posted off the main thread arrives on it")
            func arrivesOnTheMainThread() async {
                let (heard, sink) = AsyncStream.makeStream(of: Bool.self)
                let token = NotificationCenter.default.addObserver(
                    forName: Self.name, object: nil, queue: nil
                ) { _ in sink.yield(Thread.isMainThread) }
                defer { NotificationCenter.default.removeObserver(token) }
                await Task.detached { StoreNotice.post(Self.name) }.value
                var arrivedOnMain: Bool?
                for await onMain in heard {
                    arrivedOnMain = onMain
                    break
                }
                #expect(arrivedOnMain == true)
            }

            @MainActor
            @Test("A notice posted on the main thread is delivered before the post returns")
            func staysSynchronousOnTheMainThread() {
                let witness = Witness()
                NotificationCenter.default.addObserver(
                    witness, selector: #selector(Witness.noticed), name: Self.name, object: nil)
                defer { NotificationCenter.default.removeObserver(witness) }
                StoreNotice.post(Self.name)
                #expect(witness.heard == 1)
            }

            @MainActor
            @Test("A remembered catalog stored from a background task reaches a main-actor method")
            func aCatalogStoredInTheBackgroundReachesAMainActorObserver() async {
                let witness = Witness()
                NotificationCenter.default.addObserver(
                    witness, selector: #selector(Witness.noticed), name: ModelCatalogStore.didChange,
                    object: nil)
                defer { NotificationCenter.default.removeObserver(witness) }
                let profile = "store-notice-" + UUID().uuidString
                defer { ModelCatalogStore.forget(profile) }
                let models = [ModelInfo(id: "m", name: "M", providerID: "p")]
                await Task.detached { ModelCatalogStore.store(models, for: profile) }.value
                for _ in 0..<100 where witness.heard == 0 { await Task.yield() }
                #expect(witness.heard == 1)
            }

            @MainActor
            @Test("A party changed from a background task reaches a main-actor method")
            func aPartyChangedInTheBackgroundReachesAMainActorObserver() async {
                let witness = Witness()
                NotificationCenter.default.addObserver(
                    witness, selector: #selector(Witness.noticed), name: ModelParty.didChange,
                    object: nil)
                defer { NotificationCenter.default.removeObserver(witness) }
                let saved = UserDefaults.standard.string(forKey: "tailscode.modelParty")
                defer {
                    if let saved {
                        UserDefaults.standard.set(saved, forKey: "tailscode.modelParty")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "tailscode.modelParty")
                    }
                }
                let preset = ModelPreset(
                    selection: ModelSelection(providerID: "p", modelID: "store-notice-" + UUID().uuidString),
                    effort: .server)
                await Task.detached { ModelParty.place(preset) }.value
                for _ in 0..<100 where witness.heard == 0 { await Task.yield() }
                #expect(witness.heard >= 1)
            }
        #endif
    }
}

#if canImport(Darwin)
/// What a view controller is to a store: an object whose method runs on whatever thread posted,
/// and which traps there unless the post came from the main actor.
@MainActor
private final class Witness: NSObject {
    private(set) var heard = 0

    @objc func noticed() { heard += 1 }
}
#endif
