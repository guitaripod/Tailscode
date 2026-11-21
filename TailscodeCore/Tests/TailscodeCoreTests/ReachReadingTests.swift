import Testing

@testable import TailscodeCore

@Suite struct ReachReadingTests {
    @Test func everyoneAnsweringIsNoReading() {
        #expect(ReachReading.read(silent: [], answering: 3, onTailnet: true, device: .iPhone) == nil)
    }

    @Test func noTailnetAddressBlamesThisDeviceWhateverElseAnswered() {
        let reading = ReachReading.read(silent: ["arch"], answering: 2, onTailnet: false, device: .iPhone)
        #expect(reading?.suspect == .offTailnet)
        #expect(reading?.primary == .openTailscale)
        #expect(reading?.steps.map(\.action) == [.openTailscale])
    }

    @Test func everyMachineSilentAtOnceIsThisDevicesTailscale() {
        let reading = ReachReading.read(
            silent: ["arch", "macbook"], answering: 0, onTailnet: true, device: .iPhone)
        #expect(reading?.suspect == .thisDevice)
        #expect(reading?.primary == .openTailscale)
        #expect(reading?.steps.first?.action == .openTailscale)
        #expect(reading?.steps.contains { $0.action == .updateTailscale } == true)
        #expect(reading?.steps.contains { $0.action == .retry } == false)
    }

    @Test func oneSilentMachineAloneCouldBeEitherSideAndStartsWithTheSecondFix() {
        let reading = ReachReading.read(silent: ["arch"], answering: 0, onTailnet: true, device: .iPad)
        #expect(reading?.suspect == .either)
        #expect(reading?.steps.first?.action == .openTailscale)
        #expect(reading?.steps.last?.action == .retry)
        #expect(reading?.lead.contains("arch") == true)
        #expect(reading?.lead.contains("iPad") == true)
    }

    @Test func anotherMachineAnsweringClearsThisDevice() {
        let reading = ReachReading.read(silent: ["arch"], answering: 1, onTailnet: true, device: .iPhone)
        #expect(reading?.suspect == .machines)
        #expect(reading?.primary == .retry)
        #expect(reading?.steps.contains { $0.action == .updateTailscale } == false)
        #expect(reading?.steps.contains { $0.title.contains("off and on") } == false)
    }

    @Test func theTitleNamesOneMachineAndCountsMany() {
        let one = ReachReading.read(silent: ["arch"], answering: 0, onTailnet: true, device: .iPhone)
        #expect(one?.title == "arch is unreachable")
        let two = ReachReading.read(silent: ["arch", "mini"], answering: 0, onTailnet: true, device: .iPhone)
        #expect(two?.title == "2 servers are unreachable")
        #expect(two?.bannerLine == "2 servers are unreachable — tap for help")
    }

    @Test func aDeskIsToldItsOwnFix() {
        let mac = ReachReading.read(silent: ["arch", "mini"], answering: 0, onTailnet: true, device: .mac)
        #expect(mac?.deskHint.contains("menu bar") == true)
        let linux = ReachReading.read(silent: ["arch", "mini"], answering: 0, onTailnet: true, device: .linux)
        #expect(linux?.deskHint.contains("restart it") == true)
        let asleep = ReachReading.read(silent: ["arch"], answering: 1, onTailnet: true, device: .linux)
        #expect(asleep?.deskHint.contains("asleep") == true)
    }
}
