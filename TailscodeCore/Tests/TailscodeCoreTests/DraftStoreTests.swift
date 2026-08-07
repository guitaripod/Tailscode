import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("Draft store")
    struct DraftStoreTests {
        private func fresh() {
            DraftStore.forgetMemo()
            try? FileManager.default.removeItem(at: DraftStore.url)
            try? FileManager.default.removeItem(at: DraftStore.unreadableURL)
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix(DraftStore.legacyPrefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            DraftStore.forgetMemo()
        }

        /// What a restart actually is, from the store's side: the file is all that is left.
        private func restart() {
            DraftStore.flush()
            DraftStore.forgetMemo()
        }

        @Test("What was typed comes back after the process is gone")
        func survivesRestart() {
            fresh()
            let scope = DraftScope.chat(profileID: "home", sessionID: "ses_1")
            DraftStore.record("half a thought about the parser", for: scope)
            restart()
            #expect(DraftStore.text(for: scope) == "half a thought about the parser")
        }

        @Test("The same session id on two servers is two different drafts")
        func scopedByProfile() {
            fresh()
            let mine = DraftScope.chat(profileID: "laptop", sessionID: "ses_1")
            let theirs = DraftScope.chat(profileID: "desktop", sessionID: "ses_1")
            DraftStore.record("mine", for: mine)
            DraftStore.record("theirs", for: theirs)
            restart()
            #expect(DraftStore.text(for: mine) == "mine")
            #expect(DraftStore.text(for: theirs) == "theirs")
        }

        @Test("Every prompt box keeps its own text, not the chat's")
        func everyBoxIsItsOwn() {
            fresh()
            let chat = DraftScope.chat(profileID: "p", sessionID: "s")
            let compaction = DraftScope.compaction(profileID: "p", sessionID: "s")
            let goal = DraftScope.goal(profileID: "p", sessionID: "s")
            let answer = DraftScope.answer(profileID: "p", sessionID: "s", questionID: "q1")
            let home = DraftScope.home(profileID: "p", directory: "~/Dev/thing")
            DraftStore.record("the prompt", for: chat)
            DraftStore.record("keep the API decisions", for: compaction)
            DraftStore.record("the suite passes", for: goal)
            DraftStore.record("neither, actually", for: answer)
            DraftStore.record("start something new", for: home)
            restart()
            #expect(DraftStore.text(for: chat) == "the prompt")
            #expect(DraftStore.text(for: compaction) == "keep the API decisions")
            #expect(DraftStore.text(for: goal) == "the suite passes")
            #expect(DraftStore.text(for: answer) == "neither, actually")
            #expect(DraftStore.text(for: home) == "start something new")
        }

        @Test("Home's draft belongs to the folder it would start a chat in")
        func homeIsScopedToItsTarget() {
            fresh()
            let here = DraftScope.home(profileID: "p", directory: "~/Dev/one")
            let there = DraftScope.home(profileID: "p", directory: "~/Dev/two")
            DraftStore.record("about one", for: here)
            #expect(DraftStore.text(for: there).isEmpty)
            DraftStore.record("about two", for: there)
            restart()
            #expect(DraftStore.text(for: here) == "about one")
            #expect(DraftStore.text(for: there) == "about two")
        }

        @Test("Emptying the box forgets the draft rather than saving nothing")
        func emptyingClears() {
            fresh()
            let scope = DraftScope.chat(profileID: "p", sessionID: "s")
            DraftStore.record("something", for: scope)
            DraftStore.record("   \n  ", for: scope)
            restart()
            #expect(DraftStore.text(for: scope).isEmpty)
        }

        @Test("A sent prompt is gone before the next launch could hand it back")
        func clearingIsWrittenAtOnce() {
            fresh()
            let scope = DraftScope.chat(profileID: "p", sessionID: "s")
            DraftStore.record("about to be sent", for: scope)
            DraftStore.flush()
            DraftStore.clear(scope)
            DraftStore.forgetMemo()
            #expect(DraftStore.text(for: scope).isEmpty)
        }

        @Test("Nobody has to remember to save: the write follows a quiet moment")
        func writesWithoutBeingAsked() async throws {
            fresh()
            let scope = DraftScope.chat(profileID: "p", sessionID: "s")
            DraftStore.record("typed, then left alone", for: scope)
            try await Task.sleep(
                nanoseconds: UInt64((DraftStore.quietSeconds + 1.5) * 1_000_000_000))
            DraftStore.forgetMemo()
            #expect(DraftStore.text(for: scope) == "typed, then left alone")
        }

        @Test("A burst of keystrokes is one draft, not a pile of them")
        func lastWordWins() {
            fresh()
            let scope = DraftScope.chat(profileID: "p", sessionID: "s")
            for count in 1...200 { DraftStore.record(String(repeating: "a", count: count), for: scope) }
            restart()
            #expect(DraftStore.text(for: scope) == String(repeating: "a", count: 200))
        }

        @Test("The store stays bounded, and drops the oldest first")
        func boundedByCount() {
            fresh()
            for index in 0..<(DraftStore.capacity + 40) {
                DraftStore.record("draft \(index)", for: .chat(profileID: "p", sessionID: "s\(index)"))
            }
            restart()
            let newest = DraftScope.chat(
                profileID: "p", sessionID: "s\(DraftStore.capacity + 39)")
            #expect(DraftStore.text(for: newest) == "draft \(DraftStore.capacity + 39)")
            #expect(DraftStore.text(for: .chat(profileID: "p", sessionID: "s0")).isEmpty)
        }

        @Test("A draft too long for the whole budget is still kept whole")
        func theThingBeingTypedIsNeverTheOneDropped() {
            fresh()
            let small = DraftScope.chat(profileID: "p", sessionID: "small")
            let huge = DraftScope.chat(profileID: "p", sessionID: "huge")
            DraftStore.record("a modest prompt", for: small)
            let monster = String(repeating: "x", count: DraftStore.characterBudget + 1000)
            DraftStore.record(monster, for: huge)
            restart()
            #expect(DraftStore.text(for: huge) == monster)
            #expect(DraftStore.text(for: small).isEmpty)
        }

        /// Typing somewhere else must not be what evicts an over-budget draft: it is the newest
        /// entry that is protected, and only what has sat untouched longest is dropped for it.
        @Test("Typing in another chat does not evict the long draft behind it")
        func aLongDraftSurvivesTheNextKeystrokeElsewhere() {
            fresh()
            let huge = DraftScope.chat(profileID: "p", sessionID: "huge")
            let other = DraftScope.chat(profileID: "p", sessionID: "other")
            let monster = String(repeating: "x", count: DraftStore.characterBudget - 100)
            DraftStore.record(monster, for: huge)
            DraftStore.record("ok", for: other)
            restart()
            #expect(DraftStore.text(for: other) == "ok")
            #expect(DraftStore.text(for: huge) == monster)
        }

        /// A composer written to programmatically reports the deletion and the insertion as two
        /// separate edits. The empty one in the middle may never reach the disk, or a chat opened
        /// while another is being killed loses the draft it was about to show.
        @Test("Clearing and rewriting a box in one breath never lands empty")
        func anEmptyingIsCoalescedNotCommitted() {
            fresh()
            let scope = DraftScope.chat(profileID: "p", sessionID: "s")
            DraftStore.record("what was there before", for: scope)
            DraftStore.flush()
            DraftStore.record("", for: scope)
            DraftStore.record("what the restore put back", for: scope)
            DraftStore.forgetMemo()
            #expect(DraftStore.text(for: scope) == "what was there before")
            DraftStore.record("what the restore put back", for: scope)
            restart()
            #expect(DraftStore.text(for: scope) == "what the restore put back")
        }

        /// The launch that adopts an older build's drafts is also the launch that lets go of where
        /// they used to live. A `--version` that exits in between must not be what eats them.
        @Test("Adopting an older build's drafts is written before the process could exit")
        func warmingWritesTheMigration() {
            fresh()
            UserDefaults.standard.set(
                "written by the build before this one", forKey: "\(DraftStore.legacyPrefix)ses_1")
            DraftStore.forgetMemo()
            DraftStore.warm()
            DraftStore.forgetMemo()
            #expect(
                DraftStore.text(for: .chat(profileID: "p", sessionID: "ses_1"))
                    == "written by the build before this one")
        }

        /// An unclean shutdown can leave a half-written file behind. Reading it as "no drafts" would
        /// make the next keystroke the thing that destroys them.
        @Test("A file that will not decode is put aside, not written over")
        func unreadableFileIsKept() throws {
            fresh()
            DraftStore.record("worth keeping a copy of", for: .chat(profileID: "p", sessionID: "s"))
            restart()
            try Data("{ truncated".utf8).write(to: DraftStore.url)
            DraftStore.forgetMemo()
            #expect(DraftStore.text(for: .chat(profileID: "p", sessionID: "s")).isEmpty)
            DraftStore.record("something new", for: .chat(profileID: "p", sessionID: "other"))
            DraftStore.flush()
            #expect(FileManager.default.fileExists(atPath: DraftStore.unreadableURL.path))
            try? FileManager.default.removeItem(at: DraftStore.unreadableURL)
        }

        @Test("An upgrade keeps what 1.9 left half-typed")
        func adoptsLegacyKeys() {
            fresh()
            UserDefaults.standard.set(
                "typed on the desktop", forKey: "\(DraftStore.legacyPrefix)ses_desktop")
            UserDefaults.standard.set(
                "typed on the phone", forKey: "\(DraftStore.legacyPrefix)laptop/ses_phone")
            DraftStore.forgetMemo()

            let desktop = DraftScope.chat(profileID: "laptop", sessionID: "ses_desktop")
            let phone = DraftScope.chat(profileID: "laptop", sessionID: "ses_phone")
            #expect(DraftStore.text(for: desktop) == "typed on the desktop")
            #expect(DraftStore.text(for: phone) == "typed on the phone")
            #expect(
                UserDefaults.standard.string(forKey: "\(DraftStore.legacyPrefix)ses_desktop")
                    == nil)

            restart()
            #expect(DraftStore.text(for: desktop) == "typed on the desktop")
            #expect(DraftStore.text(for: phone) == "typed on the phone")
        }

        @Test("An adopted draft is claimed once, not shared by every server")
        func adoptedOnlyOnce() {
            fresh()
            UserDefaults.standard.set(
                "written before profiles were in the key",
                forKey: "\(DraftStore.legacyPrefix)ses_1")
            DraftStore.forgetMemo()

            let first = DraftScope.chat(profileID: "one", sessionID: "ses_1")
            let second = DraftScope.chat(profileID: "two", sessionID: "ses_1")
            #expect(DraftStore.text(for: first) == "written before profiles were in the key")
            #expect(DraftStore.text(for: second).isEmpty)
        }

        @Test("Forgetting everything leaves nothing behind to restore")
        func clearAllIsDurable() {
            fresh()
            let scope = DraftScope.chat(profileID: "p", sessionID: "s")
            DraftStore.record("something", for: scope)
            DraftStore.clearAll()
            DraftStore.forgetMemo()
            #expect(DraftStore.text(for: scope).isEmpty)
        }
    }
}
