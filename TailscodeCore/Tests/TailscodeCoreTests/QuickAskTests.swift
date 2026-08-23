import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Nested under `DeviceStores` on purpose: every device-local store shares one
/// `UserDefaults`, and corelibs' is not safe to write from two threads at once, so a
/// suite that writes one has to be serialized against every other suite that does.
extension DeviceStores {
    @Suite("Quick ask", .serialized)
    struct QuickAskTests {

        private func withCleanStore(_ body: () -> Void) {
            let key = "tailscode.quickask.server"
            let previous = UserDefaults.standard.string(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
            body()
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        @Test("The last quick ask's server answers the next one")
        func lastServerWins() {
            withCleanStore {
                QuickAskDefaults.record(profileID: "two")
                #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: "one") == "two")
            }
        }

        @Test("A remembered server that left the fleet falls back")
        func staleMemoryFallsBack() {
            withCleanStore {
                QuickAskDefaults.record(profileID: "gone")
                #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: "two") == "two")
            }
        }

        @Test("No memory and no fallback still aims at a server")
        func firstServerAsLastResort() {
            withCleanStore {
                #expect(QuickAskDefaults.target(among: ["one", "two"], fallback: nil) == "one")
                #expect(QuickAskDefaults.target(among: ["one"], fallback: "absent") == "one")
            }
        }

        @Test("No servers means no target — the surface's cue to offer setup")
        func emptyFleetIsNil() {
            withCleanStore {
                QuickAskDefaults.record(profileID: "one")
                #expect(QuickAskDefaults.target(among: [], fallback: nil) == nil)
            }
        }

        @Test("Clearing forgets the memory")
        func clearForgets() {
            withCleanStore {
                QuickAskDefaults.record(profileID: "one")
                QuickAskDefaults.clear()
                #expect(QuickAskDefaults.lastProfileID == nil)
            }
        }

        private func withCleanAim(_ profileID: String, _ body: () -> Void) {
            let defaults = UserDefaults.standard
            let composer = ModelPreferenceStore.globalModel(forContextID: profileID)
            defaults.removeObject(forKey: "tailscode.quickask.aimed." + profileID)
            ModelPreferenceStore.setGlobalModel(
                nil, forContextID: QuickAskDefaults.contextID(forProfileID: profileID))
            EffortPreferenceStore.setGlobalEffort(
                nil, forContextID: QuickAskDefaults.contextID(forProfileID: profileID))
            body()
            defaults.removeObject(forKey: "tailscode.quickask.aimed." + profileID)
            ModelPreferenceStore.setGlobalModel(composer, forContextID: profileID)
        }

        @Test("Until a model is picked the aim follows the server")
        func aimFollowsTheServerFirst() {
            withCleanAim("studio") {
                let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
                ModelPreferenceStore.setGlobalModel(opus, forContextID: "studio")
                #expect(!QuickAskDefaults.hasOwnAim(forProfileID: "studio"))
                #expect(QuickAskDefaults.aimContext(forProfileID: "studio") == "studio")
                #expect(QuickAskDefaults.model(forProfileID: "studio") == opus)
            }
        }

        @Test("A picked model is the quick ask's own and leaves the server's alone")
        func pickedModelStaysSeparate() {
            withCleanAim("studio") {
                let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
                let haiku = ModelSelection(providerID: "anthropic", modelID: "haiku")
                ModelPreferenceStore.setGlobalModel(opus, forContextID: "studio")
                QuickAskDefaults.recordModel(haiku, forProfileID: "studio")
                #expect(QuickAskDefaults.hasOwnAim(forProfileID: "studio"))
                #expect(QuickAskDefaults.model(forProfileID: "studio") == haiku)
                #expect(ModelPreferenceStore.globalModel(forContextID: "studio") == opus)
            }
        }

        @Test("Aiming at the server's own default is a pick, not a lack of one")
        func serverDefaultIsAPick() {
            withCleanAim("studio") {
                let opus = ModelSelection(providerID: "anthropic", modelID: "opus")
                ModelPreferenceStore.setGlobalModel(opus, forContextID: "studio")
                QuickAskDefaults.recordModel(nil, forProfileID: "studio")
                #expect(QuickAskDefaults.model(forProfileID: "studio") == nil)
                QuickAskDefaults.clearOwnAim(forProfileID: "studio")
                #expect(QuickAskDefaults.model(forProfileID: "studio") == opus)
            }
        }

        @Test("A backend that takes nothing is offered nothing")
        func noAttachmentsMeansNoRows() {
            let abilities = ModelAbilities.resolve(supportsAttachments: false, model: nil)
            #expect(!abilities.attachments)
            #expect(!abilities.vision)
            #expect(!abilities.accepts(mime: "text/plain"))
            let offered = QuickAskStarters.offered(for: abilities, recents: [])
            #expect(!offered.contains { $0.needs != .nothing })
            #expect(!offered.isEmpty)
        }

        @Test("A model the catalog cannot describe keeps the backend's word")
        func unknownModelIsTrusted() {
            let abilities = ModelAbilities.resolve(supportsAttachments: true, model: nil)
            #expect(abilities.attachments)
            #expect(abilities.vision)
        }

        @Test("A model that reads files but cannot see refuses only the pictures")
        func blindModelKeepsFiles() {
            let abilities = ModelAbilities.resolve(
                supportsAttachments: true,
                model: ModelCapabilities(attachment: true, imageInput: false, pdfInput: true))
            #expect(abilities.accepts(mime: "text/plain"))
            #expect(!abilities.accepts(mime: "image/png"))
            let offered = QuickAskStarters.offered(for: abilities, recents: [])
            #expect(offered.contains { $0.needs == .attachments })
            #expect(!offered.contains { $0.needs == .vision })
        }

        @Test("A camera belongs to the device, never to the server")
        func cameraIsTheDevices() {
            let phone = ModelAbilities.resolve(
                supportsAttachments: true, model: nil, camera: true)
            #expect(QuickAskStarters.offered(for: phone, recents: []).contains { $0.opens == .camera })
            let desk = ModelAbilities.resolve(supportsAttachments: true, model: nil)
            #expect(!QuickAskStarters.offered(for: desk, recents: []).contains { $0.opens == .camera })
        }

        @Test("What this device reaches for floats without hiding the rest")
        func recentStartersFloat() {
            let abilities = ModelAbilities.resolve(supportsAttachments: true, model: nil)
            let offered = QuickAskStarters.offered(for: abilities, recents: ["translate", "web"])
            #expect(offered.first?.id == "translate")
            #expect(offered.dropFirst().first?.id == "web")
            #expect(offered.count == QuickAskStarters.offered(for: abilities, recents: []).count)
            #expect(Set(offered.map(\.id)).count == offered.count)
        }

        @Test("A remembered errand the aim cannot carry out is dropped like any other")
        func recentStarterStillNeedsTheAim() {
            let offered = QuickAskStarters.offered(for: .words, recents: ["photo", "file"])
            #expect(!offered.contains { $0.id == "photo" || $0.id == "file" })
        }

        @Test("Every starter leaves a half-sentence and no starter sends one")
        func startersAreStems() {
            #expect(QuickAskStarters.all.allSatisfy { !$0.prompt.isEmpty })
            #expect(Set(QuickAskStarters.all.map(\.id)).count == QuickAskStarters.all.count)
        }

        @Test("Recent errands are kept newest first and bounded")
        func starterRecentsAreBounded() {
            let previous = QuickAskStarterRecents.recent()
            QuickAskStarterRecents.clear()
            for id in ["explain", "web", "image", "draft"] {
                QuickAskStarterRecents.record(id)
            }
            QuickAskStarterRecents.record("web")
            let kept = QuickAskStarterRecents.recent()
            #expect(kept.first == "web")
            #expect(kept.count == QuickAskStarterRecents.capacity)
            #expect(Set(kept).count == kept.count)
            QuickAskStarterRecents.clear()
            for id in previous.reversed() { QuickAskStarterRecents.record(id) }
        }

        @Test("Asked here is this server's project-less chats, newest first")
        func recentAsksAreProjectless() {
            let now = Date()
            func entry(_ id: String, directory: String?, ago: TimeInterval, parent: String? = nil)
                -> SessionEntry
            {
                SessionEntry(
                    profileID: "studio", profileName: "studio", host: "studio",
                    backendType: .claudeCode,
                    session: AgentSession(
                        id: id, agentType: .claudeCode, title: id, parentID: parent,
                        directory: directory, createdAt: now.addingTimeInterval(-ago),
                        updatedAt: now.addingTimeInterval(-ago)))
            }
            let elsewhere = SessionEntry(
                profileID: "laptop", profileName: "laptop", host: "laptop",
                backendType: .claudeCode,
                session: AgentSession(
                    id: "other", agentType: .claudeCode, title: "other", directory: nil,
                    createdAt: now, updatedAt: now))
            let asks = QuickAskRecents.asks(
                among: [
                    entry("old", directory: nil, ago: 900),
                    entry("project", directory: "/src", ago: 10),
                    entry("fresh", directory: nil, ago: 60),
                    entry("subagent", directory: nil, ago: 5, parent: "fresh"),
                    elsewhere,
                ], profileID: "studio")
            #expect(asks.map(\.session.id) == ["fresh", "old"])
        }

        @Test("A picture with no words is still a question")
        func attachmentAloneCanSend() {
            #expect(!QuickAskComposition.canSend(text: "  \n ", attachments: 0))
            #expect(QuickAskComposition.canSend(text: "  ", attachments: 1))
            #expect(QuickAskComposition.canSend(text: "why", attachments: 0))
        }

        @Test("The draft belongs to the machine the question is aimed at")
        func draftIsPerServer() {
            #expect(DraftScope.quickAsk(profileID: "studio").key == "ask:studio")
            #expect(
                DraftScope.quickAsk(profileID: "studio").key
                    != DraftScope.quickAsk(profileID: "laptop").key)
        }

        @Test("The minted conversation is stamped with the aim it was asked on")
        func mintCarriesTheAim() {
            withCleanAim("studio") {
                let key = QuickAskDefaults.sessionPreferenceKey(profileID: "studio", sessionID: "s1")
                let haiku = ModelSelection(providerID: "anthropic", modelID: "haiku")
                QuickAskDefaults.stamp(profileID: "studio", sessionID: "s1")
                #expect(ModelPreferenceStore.model(forKey: key) == nil)
                QuickAskDefaults.recordModel(haiku, forProfileID: "studio")
                QuickAskDefaults.recordEffort("low", forProfileID: "studio")
                QuickAskDefaults.stamp(profileID: "studio", sessionID: "s1")
                #expect(ModelPreferenceStore.model(forKey: key) == haiku)
                #expect(EffortPreferenceStore.effort(forKey: key) == "low")
                ModelPreferenceStore.setModel(nil, forKey: key)
                EffortPreferenceStore.setEffort(nil, forKey: key)
            }
        }

        @Test("Effort levels come from the picked model where the catalog names them")
        func effortFollowsTheModel() {
            let models = [
                ModelInfo(
                    id: "opus", name: "Opus", providerID: "anthropic",
                    variants: ["low", "high", "ultracode"]),
                ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic"),
            ]
            let agent = ["low", "medium", "high"]
            #expect(
                ModelEffort.options(
                    models: models,
                    selection: ModelSelection(providerID: "anthropic", modelID: "opus"),
                    agentOptions: agent) == ["low", "high", "ultracode"])
            #expect(
                ModelEffort.options(
                    models: models,
                    selection: ModelSelection(providerID: "anthropic", modelID: "haiku"),
                    agentOptions: agent) == agent)
            #expect(
                ModelEffort.options(models: models, selection: nil, agentOptions: agent)
                    == agent)
            #expect(ModelEffort.options(models: [], selection: nil, agentOptions: []).isEmpty)
        }

        @Test("An aim with no levels has no control rather than a control saying so")
        func effortLabelStatesWhatItKnows() {
            #expect(ModelEffort.label("high", options: ["low", "high"]) == "high")
            #expect(ModelEffort.label(nil, options: ["low", "high"]) == "server effort")
            #expect(ModelEffort.label(nil, options: []) == nil)
            #expect(ModelEffort.isOffered(options: []) == false)
            #expect(ModelEffort.isOffered(options: ["low"]))
        }

        @Test("Three lanes walk in one order and a swipe is that walk with a direction")
        func lanesWalkAndSwipe() {
            #expect(QuickAskLane.order == [.chat, .ask, .video])
            #expect(QuickAskLane.chat.toggled == .ask)
            #expect(QuickAskLane.ask.toggled == .video)
            #expect(QuickAskLane.video.toggled == .chat)
            #expect(QuickAskLane.chat.advanced(by: -1) == .video)
            #expect(ComposerLaneSwipe.landed(.chat, translation: -ComposerLaneSwipe.threshold) == .ask)
            #expect(ComposerLaneSwipe.landed(.chat, translation: ComposerLaneSwipe.threshold) == .video)
            #expect(ComposerLaneSwipe.landed(.chat, translation: -ComposerLaneSwipe.threshold + 1) == nil)
            #expect(ComposerLaneSwipe.offset(for: 1000) == ComposerLaneSwipe.lean)
            #expect(ComposerLaneSwipe.offset(for: -1000) == -ComposerLaneSwipe.lean)
            #expect(abs(ComposerLaneSwipe.offset(for: 30) - 10) < 0.001)
        }

        @Test("The video lane says what it costs and what it is made from")
        func videoLaneIdentity() {
            #expect(QuickAskLane.video.sendLabel != QuickAskLane.chat.sendLabel)
            #expect(QuickAskLane.video.symbol == ForgeEntryPoint.symbol)
            #expect(QuickAskLane.videoChips.allSatisfy { $0.isCyclable })
            #expect(!QuickAskLane.videoChips.contains(.prompt))
            #expect(!QuickAskLane.videoChips.contains(.endpoint))
            let words = Set(QuickAskLane.allCases.map(\.word))
            #expect(words.count == QuickAskLane.allCases.count)
        }
    }
}
