import Testing

@testable import TailscodeCore

@Suite struct StringMarkerTests {
    @Test func aMarkerInsideTheTextIsFound() {
        #expect("before <task-notification> after".holds("<task-notification>"))
        #expect("<task-notification>".holds("<task-notification>"))
        #expect("😀 <task-notification>".holds("<task-notification>"))
    }

    @Test func aMarkerThatIsNotThereIsNot() {
        #expect(!"".holds("<task-notification>"))
        #expect(!"<task-notificatio".holds("<task-notification>"))
        #expect(!"a task notification".holds("<task-notification>"))
    }

    @Test func aBridgedStringIsReadTheSameWay() {
        let long = String(repeating: "word ", count: 20_000) + "<task-notification>" + " tail"
        #expect(long.holds("<task-notification>"))
        #expect(!String(repeating: "word ", count: 20_000).holds("<task-notification>"))
    }

    @Test func anEmptyMarkerIsInEverything() {
        #expect("anything".holds(""))
        #expect("".holds(""))
    }
}
