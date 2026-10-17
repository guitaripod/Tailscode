import Foundation
import Testing

@testable import TailscodeCore

@Suite("The chooser offers the terminal's folder")
struct PaneChooserFolderTests {
    private func server(_ id: String, local: Bool) -> PaneChooserServer {
        PaneChooserServer(
            profileID: id, name: id, backend: .claudeCode, address: "\(id):4098", isLocal: local)
    }

    private func chooser(local: Bool, folder: String?) -> PaneChooser {
        var chooser = PaneChooser(servers: [server("a", local: local)], entries: [])
        chooser.setTerminalFolder(folder)
        return chooser
    }

    @Test("The folder leads the rows of a server that runs here, and Enter takes it")
    func folderLeads() {
        var chooser = chooser(local: true, folder: "/home/m/Dev/Tailscode")
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

    @Test("A server on another machine, or a shell with no folder, offers nothing")
    func absent() {
        #expect(chooser(local: false, folder: "/home/m").rows.first?.action == .newChat(profileID: "a"))
        #expect(chooser(local: true, folder: nil).rows.first?.action == .newChat(profileID: "a"))
    }

    @Test("A cursor the person moved keeps its row when the folder row appears or goes; one at the top takes the folder")
    func cursorFollowsTheRow() {
        var chooser = chooser(local: true, folder: nil)
        chooser.setTerminalFolder("/home/m/Dev")
        #expect(chooser.cursor == 0)
        #expect(chooser.rows[0].action == .newChatInFolder(profileID: "a", directory: "/home/m/Dev"))

        var moved = PaneChooser(servers: [server("a", local: true)], entries: [])
        moved.focus(1)
        let row = moved.rows[1].action
        moved.setTerminalFolder("/home/m/Dev")
        #expect(moved.rows[moved.cursor].action == row)
        moved.setTerminalFolder(nil)
        #expect(moved.rows[moved.cursor].action == row)

        chooser.setTerminalFolder(nil)
        #expect(chooser.cursor == 0)
        #expect(chooser.rows[0].action == .newChat(profileID: "a"))
    }

    @Test("A fresh listing carries the folder across")
    func restatedKeepsTheFolder() {
        let first = chooser(local: true, folder: "/srv/app")
        let next = first.restated(servers: [server("a", local: true)], entries: [])
        #expect(next.terminalFolder == "/srv/app")
        #expect(next.rows[0].action == .newChatInFolder(profileID: "a", directory: "/srv/app"))
    }

    @Test("A folder is named by its last component and written the way a shell writes it")
    func words() {
        #expect(TerminalSplit.name(of: "/home/m/Dev/Tailscode") == "Tailscode")
        #expect(TerminalSplit.name(of: "/") == "/")
        #expect(TerminalSplit.shortened("/home/m", home: "/home/m") == "~")
        #expect(TerminalSplit.shortened("/home/m/Dev", home: "/home/m") == "~/Dev")
        #expect(TerminalSplit.shortened("/home/mx/Dev", home: "/home/m") == "/home/mx/Dev")
        #expect(TerminalSplit.shortened("/srv", home: "/home/m") == "/srv")
    }
}
