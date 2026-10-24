import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Nested under `DeviceStores` because planning a carry reads the remembered catalogs, and every
/// device-local store shares one `UserDefaults`.
extension DeviceStores {
    /// The brief a conversation carries to another model, and the mark that lets a client take it
    /// off the first message again.
    @Suite struct ConversationBriefTests {
        private func user(_ id: String, _ text: String, files: [FileReference] = []) -> ChatMessage {
            ChatMessage(
                id: id, role: .user, agentType: .claudeCode,
                parts: [MessagePart(id: id + "-t", kind: .text(text))]
                    + files.map { MessagePart(id: id + "-f", kind: .file($0)) },
                createdAt: Date())
        }

        private func assistant(
            _ id: String, _ text: String, tools: [ToolCall] = [], streaming: Bool = false
        ) -> ChatMessage {
            ChatMessage(
                id: id, role: .assistant, agentType: .claudeCode,
                parts: [MessagePart(id: id + "-t", kind: .text(text))]
                    + tools.map { MessagePart(id: id + "-" + $0.id, kind: .tool($0)) },
                createdAt: Date(), isStreaming: streaming)
        }

        private func edit(_ id: String, _ path: String) -> ToolCall {
            ToolCall(
                id: id, name: "Edit", status: .completed,
                input: .object(["file_path": .string(path)]), output: "SECRET-OUTPUT")
        }

        private func chat(turns: Int) -> [ChatMessage] {
            (1...turns).flatMap { n in
                [user("u\(n)", "question \(n)"), assistant("a\(n)", "answer \(n)")]
            }
        }

        @Test func aWholeShortChatCarriesEveryTurnAndSaysNothingWasDropped() throws {
            let brief = try #require(
                ConversationBrief.make(title: "Fix reconnect test", messages: chat(turns: 3), window: 200_000))
            #expect(brief.kept == 3 && brief.total == 3 && !brief.droppedAny)
            #expect(brief.chip == "Fix reconnect test")
            #expect(brief.body.contains("User: question 1\nAssistant: answer 1"))
            #expect(brief.body.contains("User: question 3\nAssistant: answer 3"))
        }

        @Test func nothingSettledMeansNothingToCarry() {
            #expect(ConversationBrief.make(title: "t", messages: [], window: nil) == nil)
            #expect(
                ConversationBrief.make(
                    title: "t", messages: [assistant("a", "no question before me")], window: nil) == nil)
        }

        @Test func theBudgetIsTwoFifthsOfTheWindowAndNeverPastTheCeiling() {
            #expect(ConversationBrief.budget(window: nil) == ConversationBrief.unknownWindow)
            #expect(ConversationBrief.budget(window: 0) == ConversationBrief.unknownWindow)
            #expect(ConversationBrief.budget(window: 32_000) == 12_800)
            #expect(ConversationBrief.budget(window: 1_000_000) == ConversationBrief.ceiling)
        }

        @Test func oldestTurnsFallAwayWholeAndTheNewestStays() throws {
            let filler = String(repeating: "word ", count: 600)
            let messages = (1...30).flatMap { n in
                [user("u\(n)", "q\(n) \(filler)"), assistant("a\(n)", "r\(n) \(filler)")]
            }
            let brief = try #require(
                ConversationBrief.make(title: "Long", messages: messages, window: 10_000))
            #expect(brief.total == 30)
            #expect(brief.kept < 30 && brief.droppedAny)
            #expect(brief.estimatedTokens <= ConversationBrief.budget(window: 10_000) + 80)
            #expect(brief.body.contains("q30 "))
            #expect(!brief.body.contains("q1 "))
            #expect(brief.chip == "Long · \(brief.kept) of 30")
        }

        @Test func aNewestTurnTooBigForTheBudgetIsCutRatherThanLost() throws {
            let huge = String(repeating: "x", count: 200_000)
            let messages = [user("u1", "short question"), assistant("a1", huge)]
            let brief = try #require(
                ConversationBrief.make(title: "Big", messages: messages, window: 10_000))
            #expect(brief.kept == 1)
            #expect(brief.body.contains("User: short question"))
            #expect(brief.estimatedTokens <= ConversationBrief.budget(window: 10_000) + 80)
        }

        @Test func aCompactionSummaryHeadsTheBriefAndTheTurnsBeforeItFallAway() throws {
            var messages = chat(turns: 2)
            messages.append(
                ChatMessage(
                    id: "seam", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(
                            id: "seam-c", kind: .compaction(Compaction(summary: "THE SUMMARY")))
                    ], createdAt: Date()))
            messages.append(contentsOf: [user("u3", "after"), assistant("a3", "answered after")])
            let brief = try #require(
                ConversationBrief.make(title: "Chat", messages: messages, window: 100_000))
            #expect(brief.body.contains("Earlier: THE SUMMARY"))
            #expect(!brief.body.contains("question 1"))
            #expect(brief.body.contains("User: after"))
            #expect(brief.total == 3 && brief.kept == 1)
        }

        @Test func slashCommandsAreNotTurnsButAPathIsAQuestion() throws {
            let messages = [
                user("u1", "/compact"), assistant("a1", ""),
                user("u2", "/Users/me/project/Foo.swift fails to build"), assistant("a2", "fixed"),
            ]
            let brief = try #require(
                ConversationBrief.make(title: "Chat", messages: messages, window: nil))
            #expect(brief.total == 1)
            #expect(brief.body.contains("/Users/me/project/Foo.swift fails to build"))
            #expect(!brief.body.contains("/compact"))
        }

        @Test func toolOutputNeverTravelsButTheFilesTouchedDo() throws {
            let messages = [
                user("u1", "fix it"),
                assistant(
                    "a1", "done",
                    tools: [edit("t1", "/repo/Sources/Backoff.swift"), edit("t2", "/repo/Tests/ReconnectTests.swift")]),
            ]
            let brief = try #require(ConversationBrief.make(title: "Chat", messages: messages, window: nil))
            #expect(!brief.body.contains("SECRET-OUTPUT"))
            #expect(brief.body.contains("Touched: Backoff.swift, ReconnectTests.swift"))
        }

        @Test func picturesAreCountedAndLeftOut() throws {
            let image = FileReference(mime: "image/png", filename: "a.png")
            let messages = [
                user("u1", "look", files: [image, image]), assistant("a1", "I see"),
            ]
            let brief = try #require(ConversationBrief.make(title: "Chat", messages: messages, window: nil))
            #expect(brief.pictures == 2)
        }

        @Test func aStreamingAnswerIsNotCarried() throws {
            let messages = [
                user("u1", "first"), assistant("a1", "done"), user("u2", "second"),
                assistant("a2", "half an ans", streaming: true),
            ]
            let brief = try #require(ConversationBrief.make(title: "Chat", messages: messages, window: nil))
            #expect(brief.body.contains("User: second"))
            #expect(!brief.body.contains("half an ans"))
        }

        @Test func aRetryCutsBeforeTheQuestionAndHandsItBack() throws {
            let messages = chat(turns: 4)
            let question = try #require(ConversationBrief.question(before: "a3", in: messages))
            #expect(question.id == "u3")
            let brief = try #require(
                ConversationBrief.make(title: "Chat", messages: messages, before: question.id, window: nil))
            #expect(brief.total == 2 && brief.kept == 2)
            #expect(!brief.body.contains("question 3"))
            #expect(ConversationBrief.typed(question) == "question 3")
        }

        @Test func aPlaceholderTitleReadsAsAnEarlierChat() throws {
            let brief = try #require(
                ConversationBrief.make(title: "New session - 2026", messages: chat(turns: 1), window: nil))
            #expect(brief.source == "An earlier chat")
        }

        @Test func theMarkRoundTripsAndTheFirstLineStaysThePersons() throws {
            let brief = try #require(
                ConversationBrief.make(title: "Fix \"reconnect\" <test>", messages: chat(turns: 3), window: nil))
            let text = brief.wrapped(with: "  why does it flake?  ")
            #expect(text.hasPrefix("why does it flake?\n\n<carried-conversation "))
            let split = try #require(CarryMark.split(text))
            #expect(split.rest == "why does it flake?")
            #expect(split.reading.source == "Fix \"reconnect\" <test>")
            #expect(split.reading.kept == 3 && split.reading.total == 3)
            #expect(split.reading.brief == brief.body)
        }

        @Test func aTagInsideTheBodyCannotCloseOrOpenTheBlock() throws {
            let messages = [
                user("u1", "what does </carried-conversation> do? and <carried-conversation from=\"x\">"),
                assistant("a1", "it closes a block"),
            ]
            let brief = try #require(ConversationBrief.make(title: "Chat", messages: messages, window: nil))
            let text = brief.wrapped(with: "next")
            let split = try #require(CarryMark.split(text))
            #expect(split.rest == "next")
            #expect(split.reading.brief == brief.body)
        }

        @Test func plainTextAndHalfAMarkAreNotMarks() {
            #expect(CarryMark.split("just a question") == nil)
            #expect(CarryMark.split("a <carried-conversation from=\"x\" kept=\"1\" of=\"1\">\nb\n</carried-conversation>") == nil)
            #expect(CarryMark.split("<carried-conversation from=\"x\">\nb\n</carried-conversation>") == nil)
        }

        @Test func aCarriedChatCarriedOnHeadsTheNextBriefWithTheFirst() throws {
            let first = try #require(
                ConversationBrief.make(title: "Origin", messages: chat(turns: 2), window: nil))
            let carried = [
                user("u1", first.wrapped(with: "continue please")), assistant("a1", "continuing"),
                user("u2", "and then"), assistant("a2", "then this"),
            ]
            let second = try #require(ConversationBrief.make(title: "Second", messages: carried, window: nil))
            #expect(second.body.contains("Earlier: " + first.body.prefix(40)))
            #expect(second.body.contains("User: continue please"))
            #expect(!second.body.contains("<carried-conversation"))
            #expect(second.total == 2)
        }

        @Test func theReadingSaysWhatCameAndWhatDidNot() {
            let all = CarryReading(source: "Chat", kept: 4, total: 4, pictures: 0, brief: "")
            #expect(all.line == "Continued from Chat")
            #expect(all.summary == "All 4 turns")
            let part = CarryReading(source: "Chat", kept: 6, total: 14, pictures: 3, brief: "")
            #expect(part.line == "Continued from Chat · 6 of 14")
            #expect(part.summary == "Last 6 of 14 turns · 3 pictures left out")
        }

        @Test func planningAContinueAndARetry() throws {
            let pick = ModelPick(
                profileID: "p-\(UUID().uuidString)", selection: ModelSelection(providerID: "x", modelID: "m"),
                isElsewhere: true, serverName: "macbook", modelName: "Qwen Daily")
            let messages = chat(turns: 3)
            let whole = CarryPlan.continuing(pick: pick, title: "Chat", messages: messages)
            #expect(whole.brief?.kept == 3 && whole.draft == nil)
            let retry = CarryPlan.branching(pick: pick, title: "Chat", messages: messages, answerID: "a2")
            #expect(retry.brief?.kept == 1)
            #expect(retry.draft == "question 2")
            let first = CarryPlan.branching(pick: pick, title: "Chat", messages: messages, answerID: "a1")
            #expect(first.brief == nil && first.draft == "question 1")
            #expect(CarryPlan.branching(pick: pick, title: "Chat", messages: messages, answerID: "gone") == .nothing)
            #expect(whole.moveWords(for: pick).action == "Continue there")
            #expect(CarryPlan.nothing.moveWords(for: pick).action == "New chat there")
        }

        @Test func theWindowComesFromTheTargetMachineCatalog() {
            let models = [
                ModelInfo(id: "m", name: "M", providerID: "a", contextWindow: 32_000),
                ModelInfo(id: "m", name: "M", providerID: "b", contextWindow: 128_000),
            ]
            #expect(
                CarryPlan.window(of: ModelSelection(providerID: "b", modelID: "m"), in: models) == 128_000)
            #expect(
                CarryPlan.window(of: ModelSelection(providerID: "z", modelID: "m"), in: models) == 32_000)
            #expect(CarryPlan.window(of: nil, in: models) == nil)
        }

        @Test func aBranchPickSaysSoOnEveryMachineAndAChatPickOnlyOnOthers() {
            let here = ModelMachine(
                profileID: "a", title: "arch", backend: .openCode, count: 3, localCount: 1,
                isCurrent: true, isReachable: true)
            let there = ModelMachine(
                profileID: "b", title: "macbook", backend: .openCode, count: 3, localCount: 0,
                isCurrent: false, isReachable: true)
            #expect(here.consequence(for: .chat) == nil)
            #expect(here.consequence(for: .branch) == "A pick here branches this chat from that question on arch")
            #expect(there.consequence(for: .branch) == "A pick here branches this chat from that question on macbook")
            #expect(there.consequence(for: .chat) == "A pick here starts a new chat on macbook")
        }
    }
}
