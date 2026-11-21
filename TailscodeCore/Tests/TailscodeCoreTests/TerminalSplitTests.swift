import Foundation
import Testing

@testable import TailscodeCore

@Suite("Split into the terminal's folder")
struct TerminalSplitTests {
    @Test("The chat goes to the server that holds the shell, in the folder the shell stands in")
    func opensWhereTheShellStands() {
        #expect(
            TerminalSplit.plan(directory: "/home/m/Dev", server: "macbook")
                == .open(profileID: "macbook", directory: "/home/m/Dev"))
    }

    @Test("No shell refuses in words, and so does a shell whose folder could not be read")
    func refusals() {
        #expect(TerminalSplit.plan(directory: "/a", server: nil) == .refused(.noTerminal))
        #expect(TerminalSplit.plan(directory: nil, server: "arch") == .refused(.noDirectory))
        #expect(TerminalSplit.plan(directory: "relative", server: "arch") == .refused(.noDirectory))
        for refusal in [TerminalSplit.Refusal.noTerminal, .noDirectory] {
            #expect(!refusal.words.isEmpty)
        }
    }

    @Test("A folder is named by its last part and written the way a prompt writes it")
    func names() {
        #expect(TerminalSplit.name(of: "/home/m/Dev/Tailscode") == "Tailscode")
        #expect(TerminalSplit.name(of: "/") == "/")
        #expect(TerminalSplit.shortened("/home/m/Dev/Tailscode") == "~/Dev/Tailscode")
        #expect(TerminalSplit.shortened("/srv/www") == "/srv/www")
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
