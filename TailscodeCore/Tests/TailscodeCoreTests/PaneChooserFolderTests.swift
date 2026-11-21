import Foundation
import Testing

@testable import TailscodeCore

@Suite("The chooser offers the terminal's folder")
struct PaneChooserFolderTests {
    private func server(_ id: String, local: Bool) -> PaneChooserServer {
        PaneChooserServer(
            profileID: id, name: id, backend: .claudeCode, address: "\(id):4098", isLocal: local)
    }

    private func chooser(holdsShell: Bool, folder: String?) -> PaneChooser {
        var chooser = PaneChooser(servers: [server("a", local: false)], entries: [])
        chooser.setTerminalFolder(folder, on: holdsShell ? "a" : "elsewhere")
        return chooser
    }

    @Test("The folder leads the rows of the server that holds the shell, and Enter takes it")
    func folderLeads() {
        var chooser = chooser(holdsShell: true, folder: "/home/m/Dev/Tailscode")
        let rows = chooser.rows
        #expect(
            rows[0].action
                == .newChatInFolder(profileID: "a", directory: "/home/m/Dev/Tailscode"))
        #expect(rows[0].isPrimary)
        #expect(rows[0].title.contains("Tailscode"))
        #expect(rows[1].action == .newChat(profileID: "a"))
        #expect(chooser.cursor == 0)
        #expect(
            chooser.handle(.activate).action
                == .newChatInFolder(profileID: "a", directory: "/home/m/Dev/Tailscode"))
    }

    @Test("A server that does not hold the shell, or a shell with no folder, offers nothing")
    func absent() {
        #expect(chooser(holdsShell: false, folder: "/home/m").rows.first?.action == .newChat(profileID: "a"))
        #expect(chooser(holdsShell: true, folder: nil).rows.first?.action == .newChat(profileID: "a"))
    }

    @Test("A cursor the person moved keeps its row when the folder row appears or goes; one at the top takes the folder")
    func cursorFollowsTheRow() {
        var chooser = chooser(holdsShell: true, folder: nil)
        chooser.setTerminalFolder("/home/m/Dev", on: "a")
        #expect(chooser.cursor == 0)
        #expect(chooser.rows[0].action == .newChatInFolder(profileID: "a", directory: "/home/m/Dev"))

        var moved = PaneChooser(servers: [server("a", local: true)], entries: [])
        moved.focus(1)
        let row = moved.rows[1].action
        moved.setTerminalFolder("/home/m/Dev", on: "a")
        #expect(moved.rows[moved.cursor].action == row)
        moved.setTerminalFolder(nil, on: "a")
        #expect(moved.rows[moved.cursor].action == row)

        chooser.setTerminalFolder(nil, on: "a")
        #expect(chooser.cursor == 0)
        #expect(chooser.rows[0].action == .newChat(profileID: "a"))
    }

    @Test("A fresh listing carries the folder across")
    func restatedKeepsTheFolder() {
        let first = chooser(holdsShell: true, folder: "/srv/app")
        let next = first.restated(servers: [server("a", local: false)], entries: [])
        #expect(next.terminalFolder == "/srv/app")
        #expect(next.rows[0].action == .newChatInFolder(profileID: "a", directory: "/srv/app"))
    }

    @Test("A folder is named by its last component and written the way a shell writes it")
    func words() {
        #expect(TerminalSplit.name(of: "/home/m/Dev/Tailscode") == "Tailscode")
        #expect(TerminalSplit.name(of: "/") == "/")
        #expect(TerminalSplit.shortened("/home/m") == "~")
        #expect(TerminalSplit.shortened("/home/m/Dev") == "~/Dev")
        #expect(TerminalSplit.shortened("/Users/m/Dev") == "~/Dev")
        #expect(TerminalSplit.shortened("/srv") == "/srv")
    }
}
