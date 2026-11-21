import Foundation
import Testing

@testable import TailscodeCore

@Suite struct WelcomeLookTests {
    @Test func onlySomebodyNewWhoChoseNothingIsDressed() {
        #expect(WelcomeLook.themeForNewcomer(isNewcomer: true, stored: nil) == "outerrim")
        #expect(WelcomeLook.themeForNewcomer(isNewcomer: false, stored: nil) == nil)
        #expect(WelcomeLook.themeForNewcomer(isNewcomer: true, stored: "gruvbox") == nil)
    }

    @Test func theRowOffersTheNewcomersLookAndThePlainOne() {
        let look = WelcomeLook.reading(wearing: "outerrim", plain: ThemeSelection.systemID)
        #expect(look.choices.map(\.id) == ["outerrim", "system"])
        #expect(look.choices.map(\.isChosen) == [true, false])
        #expect(look.choices[0].title == "Outer Rim")
        #expect(!look.title.isEmpty && !look.caption.isEmpty)
        let desktop = WelcomeLook.reading(wearing: AppTheme.fallback.id, plain: AppTheme.fallback.id)
        #expect(desktop.choices.map(\.isChosen) == [false, true])
        #expect(desktop.choices[1].title == AppTheme.fallback.name)
        #expect(WelcomeLook.reading(wearing: "outerrim", plain: "outerrim").choices.count == 1)
    }
}
