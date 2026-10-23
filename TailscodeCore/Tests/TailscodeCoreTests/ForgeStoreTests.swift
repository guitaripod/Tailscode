import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Nested under `DeviceStores` on purpose: every device-local store shares one `UserDefaults`, and
/// corelibs' is not safe to write from two threads at once, so a suite that writes one has to be
/// serialized against every other suite that does.
extension DeviceStores {
    @Suite("Forge store")
    struct ForgeStoreTests {
        private func fresh() {
            UserDefaults.standard.removeObject(forKey: ForgeStore.endpointKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.recipeKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.historyKey)
        }

        @Test("The machine that renders survives the app being gone")
        func endpointRoundTrip() {
            fresh()
            #expect(ForgeStore.endpoint() == nil)
            ForgeStore.remember(ForgeEndpoint(host: "arch", port: 9000))
            #expect(ForgeStore.endpoint() == ForgeEndpoint(host: "arch", port: 9000))
            ForgeStore.remember(nil)
            #expect(ForgeStore.endpoint() == nil)
            fresh()
        }

        @Test("The settings come back but the words do not")
        func recipeRoundTrip() {
            fresh()
            #expect(ForgeStore.recipe().prompt.isEmpty)
            let recipe = ForgeRecipe(
                prompt: "a cat", negative: "blurry", sound: "rain", frame: .kept("a.png [output]"),
                width: 704, height: 1280, seconds: 8, fps: 30, seed: 12345)
            ForgeStore.remember(recipe)
            let read = ForgeStore.recipe()
            #expect(read.prompt.isEmpty, "a new box asks for something new")
            #expect(read.sound.isEmpty, "and is not still hearing yesterday's rain")
            #expect(read.frame == nil, "nor opening on yesterday's picture")
            #expect(read.negative == "blurry")
            #expect(read.size == ForgeSize.portrait)
            #expect(read.seconds == 8)
            #expect(read.fps == 30)
            #expect(read.seed == 12345)
            #expect(read.length == 8 * 30 + 1)
            fresh()
        }

        @Test("A clip that was made is still listed, newest first, and only once")
        func historyRoundTrip() {
            fresh()
            #expect(ForgeStore.history().isEmpty)
            let recipe = ForgeRecipe(prompt: "a cat", seed: 3)
            let first = ForgeEntry(
                id: "one", recipe: recipe, asset: ForgeAsset(filename: "one.mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let second = ForgeEntry(
                id: "two", recipe: recipe, asset: nil, failure: "out of memory",
                finishedAt: Date(timeIntervalSince1970: 1_700_000_100))
            ForgeStore.record(first)
            ForgeStore.record(second)
            #expect(ForgeStore.history().map(\.id) == ["two", "one"])
            ForgeStore.record(first)
            #expect(ForgeStore.history().map(\.id) == ["one", "two"], "a repeat is moved, not doubled")
            let read = ForgeStore.history()[0]
            #expect(read.recipe.seed == 3)
            #expect(read.asset?.filename == "one.mp4")
            #expect(read.isPlayable)
            #expect(ForgeStore.history()[1].failure == "out of memory")
            ForgeStore.remove("one")
            #expect(ForgeStore.history().map(\.id) == ["two"])
            ForgeStore.forget()
            #expect(ForgeStore.history().isEmpty)
            fresh()
        }

        @Test("Every machine this device has rendered on is offered back, most recent first")
        func renderersRoundTrip() {
            UserDefaults.standard.removeObject(forKey: ForgeStore.renderersKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.endpointKey)
            #expect(ForgeStore.renderers().isEmpty)
            ForgeStore.remember(ForgeRenderer(endpoint: ForgeEndpoint(host: "arch"), name: "arch"))
            ForgeStore.remember(ForgeRenderer(endpoint: ForgeEndpoint(host: "studio"), name: "studio"))
            #expect(ForgeStore.renderers().map(\.id) == ["studio:8188", "arch:8188"])
            #expect(ForgeStore.endpoint() == ForgeEndpoint(host: "studio"))
            ForgeStore.remember(ForgeRenderer(endpoint: ForgeEndpoint(host: "arch")))
            #expect(ForgeStore.renderers().map(\.id) == ["arch:8188", "studio:8188"], "a machine used again moves rather than doubles")
            #expect(ForgeStore.renderers()[0].name == "arch", "and a name once learned is not thrown away")
            ForgeStore.remember(ForgeEndpoint(host: "box"))
            #expect(ForgeStore.renderers().map(\.id).first == "box:8188", "an address typed blind is filed too")
            #expect(ForgeStore.renderers()[0].name == nil)
            ForgeStore.forgetRenderer("box:8188")
            #expect(ForgeStore.renderers().map(\.id) == ["arch:8188", "studio:8188"])
            #expect(ForgeStore.endpoint() == nil, "forgetting the machine in use stops sending work to it")
            UserDefaults.standard.removeObject(forKey: ForgeStore.renderersKey)
            UserDefaults.standard.removeObject(forKey: ForgeStore.endpointKey)
        }

        @Test("A render that is out survives the app being gone, and filing its clip settles it")
        func pendingRoundTrip() {
            fresh()
            UserDefaults.standard.removeObject(forKey: ForgeStore.pendingKey)
            #expect(ForgeStore.pending() == nil)
            let pending = ForgePending(
                promptID: "pid", clientID: "client", endpoint: ForgeEndpoint(host: "arch"),
                recipe: ForgeRecipe(prompt: "a cat"), startedAt: Date(), nodes: 28, confirmed: true)
            ForgeStore.remember(pending: pending)
            #expect(ForgeStore.pending() == pending)
            ForgeStore.clearPending("another")
            #expect(ForgeStore.pending() == pending, "a late call about a replaced render leaves the newer one")
            ForgeStore.record(
                ForgeEntry(
                    id: "pid", recipe: pending.recipe, asset: nil, failure: "Lost contact"))
            #expect(ForgeStore.pending() == pending, "a lost render is not a settled one")
            ForgeStore.record(
                ForgeEntry(
                    id: "pid", recipe: pending.recipe,
                    asset: ForgeAsset(filename: "a.mp4", subfolder: "video")))
            #expect(ForgeStore.pending() == nil, "filing the clip is what settles the render")
            fresh()
        }

        @Test("A render nobody is going to look for any more is let go")
        func pendingExpires() {
            fresh()
            let old = ForgePending(
                promptID: "pid", clientID: "client", endpoint: ForgeEndpoint(host: "arch"),
                recipe: ForgeRecipe(prompt: "a cat"),
                startedAt: Date().addingTimeInterval(-ForgeStore.pendingLifetime - 60), nodes: 28)
            ForgeStore.remember(pending: old)
            #expect(ForgeStore.pending() == nil)
            #expect(ForgeStore.pending(now: old.startedAt.addingTimeInterval(60)) == nil, "and it stays let go")
            fresh()
        }

        @Test("A receipt knows which machine wrote the file")
        func entriesRememberTheirMachine() {
            fresh()
            var job = ForgeJob(recipe: ForgeRecipe(prompt: "a cat"))
            job.submitting()
            job.accepted(promptID: "pid")
            job.delivered(ForgeAsset(filename: "a.mp4", subfolder: "video"))
            let arch = ForgeEndpoint(host: "arch")
            let studio = ForgeEndpoint(host: "studio")
            let entry = ForgeStore.record(job, on: arch)
            #expect(entry?.endpoint == arch)
            #expect(ForgeStore.history().first?.endpoint == arch, "it is kept, not just returned")
            #expect(entry?.isOn(arch) == true)
            #expect(entry?.isOn(studio) == false, "the same name on another machine is another clip")
            let old = ForgeEntry(id: "old", recipe: ForgeRecipe(), asset: nil)
            #expect(old.isOn(studio), "a receipt from before machines were recorded is read as the current one")
            fresh()
        }

        @Test("Only a job that actually stopped becomes history")
        func onlyFinishedJobsAreFiled() {
            fresh()
            var job = ForgeJob(recipe: ForgeRecipe(prompt: "a cat"))
            #expect(ForgeStore.record(job) == nil)
            job.submitting()
            job.accepted(promptID: "pid")
            #expect(ForgeStore.record(job) == nil, "a render in flight is not a receipt")
            job.delivered(ForgeAsset(filename: "a.mp4", subfolder: "video"))
            let entry = ForgeStore.record(job)
            #expect(entry?.id == "pid")
            #expect(ForgeStore.history().count == 1)
            fresh()
        }
    }
}
