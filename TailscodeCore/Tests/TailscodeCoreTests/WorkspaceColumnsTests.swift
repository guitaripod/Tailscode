import Testing

@testable import TailscodeCore

@Suite struct WorkspaceColumnsTests {
    @Test func compactWindowIsThePhoneStack() {
        #expect(WorkspaceColumns.fit(width: 592, height: 834, compact: true) == .stack)
        #expect(WorkspaceColumns.fit(width: 375, height: 834, compact: true) == .stack)
    }

    @Test func thirteenInchOnItsSideShowsAllThree() {
        #expect(WorkspaceColumns.fit(width: 1376, height: 1032, compact: false) == .all)
        #expect(WorkspaceColumns.fit(width: 1366, height: 1024, compact: false) == .all)
    }

    @Test func elevenInchOnItsSideKeepsTheListBesideAWholeConversation() {
        #expect(WorkspaceColumns.fit(width: 1194, height: 834, compact: false) == .listBeside)
        #expect(WorkspaceColumns.fit(width: 1210, height: 834, compact: false) == .listBeside)
        #expect(WorkspaceColumns.fit(width: 1133, height: 744, compact: false) == .listBeside)
    }

    @Test func thirteenInchUprightKeepsTheList() {
        #expect(WorkspaceColumns.fit(width: 1032, height: 1376, compact: false) == .listBeside)
    }

    @Test func twoThirdsSplitAndUprightElevenInchGiveTheConversationTheWindow() {
        #expect(WorkspaceColumns.fit(width: 834, height: 834, compact: false) == .conversation)
        #expect(WorkspaceColumns.fit(width: 834, height: 1194, compact: false) == .conversation)
        #expect(WorkspaceColumns.fit(width: 834, height: 603, compact: false) == .conversation)
        #expect(WorkspaceColumns.fit(width: 744, height: 1133, compact: false) == .conversation)
    }

    @Test func phoneOnItsSideKeepsTheListBesideTheConversation() {
        #expect(WorkspaceColumns.fit(width: 874, height: 402, compact: false) == .listBeside)
        #expect(WorkspaceColumns.fit(width: 956, height: 440, compact: false) == .listBeside)
        #expect(WorkspaceColumns.fit(width: 951, height: 669, compact: false) == .listBeside)
    }

    @Test func everyArrangementLeavesTheConversationItsMinimum() {
        var width = 700.0
        while width <= 1400 {
            let columns = WorkspaceColumns.fit(width: width, height: 1000, compact: false)
            let list = WorkspaceColumns.listColumnWidth(columns, width: width)
            let taken: Double
            switch columns {
            case .all: taken = WorkspaceColumns.sidebarWidth + list
            case .listBeside: taken = list
            case .conversation, .stack: taken = 0
            }
            #expect(width - taken >= WorkspaceColumns.conversationMinimum, "width \(width)")
            width += 2
        }
    }

    @Test func listWidensOnlyWithRoomToSpare() {
        #expect(WorkspaceColumns.listColumnWidth(.listBeside, width: 960) == 320)
        #expect(WorkspaceColumns.listColumnWidth(.listBeside, width: 1194) == 334)
        #expect(WorkspaceColumns.listColumnWidth(.listBeside, width: 1270) == 360)
        #expect(WorkspaceColumns.listColumnWidth(.all, width: 1376) == 360)
    }
}
