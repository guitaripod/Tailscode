import Foundation
import Testing
@testable import TailscodeCore

@Suite("Game Center consent")
struct GameCenterConsentTests {
    private func consent() -> (GameCenterConsent, UserDefaults) {
        let suite = "tailscode.test.gamecenter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return (GameCenterConsent(defaults: defaults), defaults)
    }

    @Test("a fresh install has not asked for Game Center")
    func freshInstallIsOff() {
        let (consent, _) = consent()
        #expect(!consent.isOn)
    }

    @Test("turning it on is remembered, and turning it off wins over it")
    func choiceIsRemembered() {
        let (consent, _) = consent()
        consent.turnOn()
        #expect(consent.isOn)
        consent.turnOff()
        #expect(!consent.isOn)
    }

    @Test("having reported before is not asking")
    func earlierReportIsNotConsent() {
        let (consent, defaults) = consent()
        defaults.set("player-1", forKey: GameCenterConsent.reportedPlayerKey)
        #expect(!consent.isOn)
    }

    @Test("the off state has a sentence of its own")
    func offHasWords() {
        #expect(GameCenterReading.off.line.contains("off"))
        #expect(GameCenterReading.off.line != GameCenterReading.signedOut.line)
    }
}
