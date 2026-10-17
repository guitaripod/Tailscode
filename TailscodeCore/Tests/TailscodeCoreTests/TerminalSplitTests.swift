import Foundation
import Testing

@testable import TailscodeCore

@Suite("Split into the terminal's folder")
struct TerminalSplitTests {
    private let here = TerminalSplit.Server(profileID: "here", isLocal: true)
    private let elsewhere = TerminalSplit.Server(profileID: "elsewhere", isLocal: false)

    @Test("The pane's own server wins when the terminal's disk is its disk")
    func prefersThePanesServer() {
        let other = TerminalSplit.Server(profileID: "other", isLocal: true)
        let plan = TerminalSplit.plan(
            directory: "/home/m/Dev", servers: [other, here], preferred: "here")
        #expect(plan == .open(profileID: "here", directory: "/home/m/Dev"))
    }

    @Test("A pane on another machine does not drag the chat there")
    func skipsServersOnOtherMachines() {
        let plan = TerminalSplit.plan(
            directory: "/home/m/Dev", servers: [elsewhere, here], preferred: "elsewhere")
        #expect(plan == .open(profileID: "here", directory: "/home/m/Dev"))
    }

    @Test("A local server that answers outranks one that does not, and one that does not still beats none")
    func prefersAnswering() {
        let down = TerminalSplit.Server(profileID: "down", isLocal: true, reachable: false)
        #expect(
            TerminalSplit.plan(directory: "/a", servers: [down, here], preferred: "down")
                == .open(profileID: "here", directory: "/a"))
        #expect(
            TerminalSplit.plan(directory: "/a", servers: [down], preferred: nil)
                == .open(profileID: "down", directory: "/a"))
    }

    @Test("Nothing local refuses in words, and so does no folder")
    func refusals() {
        #expect(
            TerminalSplit.plan(directory: "/a", servers: [elsewhere], preferred: nil)
                == .refused(.noLocalServer))
        #expect(TerminalSplit.plan(directory: nil, servers: [here], preferred: nil) == .refused(.noDirectory))
        for refusal in [TerminalSplit.Refusal.oneCommandAtATime, .noDirectory, .noLocalServer] {
            #expect(!refusal.words.isEmpty)
        }
    }

    @Test("A shell's working-directory link is a folder only when it names a place that exists")
    func directoryFromLink() {
        #expect(TerminalSplit.directory(fromLink: "/home/m/Dev") == "/home/m/Dev")
        #expect(TerminalSplit.directory(fromLink: "/home/m/gone (deleted)") == nil)
        #expect(TerminalSplit.directory(fromLink: "relative") == nil)
        #expect(TerminalSplit.directory(fromLink: nil) == nil)
    }

    @Test("The split chords are registered in every context and clash with nothing")
    func chordsAreRegistered() {
        let set = ShortcutSet.build(overrides: [:])
        #expect(set.issues.isEmpty)
        let ids = Set(ShortcutRegistry.all.map(\.id))
        #expect(ids.isSuperset(of: ["split.hereRight", "split.hereDown"]))
        let right = KeySpec.parse("ctrl+shift+o")!.chords[0]
        let down = KeySpec.parse("ctrl+alt+shift+o")!.chords[0]
        for context in KeyContext.allCases {
            #expect(
                set.resolve(right, context: context, pending: [], awaitingApproval: false)
                    == .run(.splitAtTerminal(.horizontal)))
            #expect(
                set.resolve(down, context: context, pending: [], awaitingApproval: false)
                    == .run(.splitAtTerminal(.vertical)))
        }
    }
}
