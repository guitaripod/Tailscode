import Foundation
import Testing

@testable import TailscodeCore

/// The catalog, checked as data rather than looked at. A palette is a claim about legibility, and
/// the claim is the same on a GTK canvas, a phone's transcript and a Mac window — so it is proved
/// once, here, and no client can ship a theme its own eye happened not to catch.
@Suite struct ThemeTests {
    private static let signalSlots: [(String, KeyPath<Palette, String> & Sendable)] = [
        ("accent", \.accent), ("warn", \.warn), ("danger", \.danger),
        ("info", \.info), ("special", \.special), ("textDim", \.textDim),
    ]

    private static let everySlot: [KeyPath<Palette, String> & Sendable] = [
        \.canvas, \.canvasRaised, \.rule, \.text, \.textDim, \.accent, \.accentDim, \.warn,
        \.danger, \.info, \.special, \.codeBg, \.subagentBg, \.findHit, \.onAccent,
        \.brandClaude, \.brandOpencode, \.brandGrok, \.brandDeepseek, \.terminalFg, \.terminalBg,
    ]

    private static var published: [Palette] {
        AppTheme.all.flatMap { [$0.dark.corrected(), $0.light.corrected()] }
    }

    @Test func catalogIsAddressable() {
        var ids = Set<String>()
        var names = Set<String>()
        for theme in AppTheme.all {
            #expect(ids.insert(theme.id).inserted, "two themes answer to \(theme.id)")
            #expect(names.insert(theme.name).inserted, "two themes are called \(theme.name)")
            #expect(!theme.blurb.isEmpty)
            #expect(AppTheme.named(theme.id) == theme)
            #expect(theme.dark.isDark && !theme.light.isDark)
            #expect(theme.dark.name != theme.light.name)
        }
        #expect(AppTheme.named("no-such-theme") == AppTheme.fallback)
        #expect(AppTheme.named(nil) == AppTheme.fallback)
    }

    @Test func everySlotIsAColour() {
        for palette in Self.published {
            for slot in Self.everySlot {
                let value = palette[keyPath: slot]
                #expect(
                    value.hasPrefix("#") && value.count == 7
                        && value.dropFirst().allSatisfy(\.isHexDigit),
                    "\(palette.name): \(value) is not a colour")
            }
            #expect(palette.ansi.count == 16, "\(palette.name): the terminal wants sixteen")
            for colour in palette.ansi {
                #expect(colour.hasPrefix("#") && colour.count == 7)
            }
        }
    }

    /// The published palette clears its own contract, which is the whole point of `corrected()`:
    /// a theme that cannot be made readable fails the build rather than shipping as a pretty
    /// palette nobody can use.
    @Test func publishedPalettesClearTheirContract() {
        for palette in Self.published {
            for rule in palette.contrastContract {
                let ratio = Contrast.ratio(rule.color, on: rule.against)
                #expect(ratio != nil, "\(palette.name): \(rule.slot) is not measurable")
                #expect(
                    (ratio ?? 0) >= rule.ratio,
                    "\(palette.name): \(rule.slot) reads at \(ratio ?? 0), needs \(rule.ratio)")
            }
        }
    }

    /// Two meanings that wear the same colour are one meaning to a reader.
    @Test func signalsStayTellableApart() {
        for palette in Self.published {
            for (index, one) in Self.signalSlots.enumerated() {
                for other in Self.signalSlots.dropFirst(index + 1) {
                    #expect(
                        palette[keyPath: one.1] != palette[keyPath: other.1],
                        "\(palette.name): \(one.0) and \(other.0) are the same colour")
                }
            }
        }
    }

    @Test func canvasAgreesWithAppearance() {
        for palette in Self.published {
            #expect(
                palette.isDark == ((Contrast.luminance(palette.canvas) ?? 1) < 0.18),
                "\(palette.name): its canvas disagrees with isDark")
        }
    }

    /// Correction moves lightness and nothing else, so a corrected slot is still recognisably the
    /// theme's own colour rather than a grey the arithmetic settled on.
    @Test func correctionKeepsTheHue() {
        for theme in AppTheme.all {
            for authored in [theme.dark, theme.light] {
                let published = authored.corrected()
                for slot in Self.signalSlots.map(\.1) where authored[keyPath: slot] != published[keyPath: slot] {
                    let was = Contrast.channels(authored[keyPath: slot])
                    let now = Contrast.channels(published[keyPath: slot])
                    #expect(was != nil && now != nil)
                    guard let was, let now else { continue }
                    let wasSpread = max(was.red, was.green, was.blue) - min(was.red, was.green, was.blue)
                    let nowSpread = max(now.red, now.green, now.blue) - min(now.red, now.green, now.blue)
                    #expect(
                        wasSpread < 0.04 || nowSpread > wasSpread * 0.3,
                        "\(authored.name): correcting \(authored[keyPath: slot]) flattened it to \(published[keyPath: slot])")
                }
            }
        }
    }

    /// A palette that already reads is left exactly as its author wrote it.
    @Test func correctionLeavesGoodColoursAlone() {
        let phosphor = AppTheme.phosphor.dark
        #expect(phosphor.corrected().accent == phosphor.accent)
        #expect(phosphor.corrected().canvas == phosphor.canvas)
    }

    @Test func choosingAThemeReachesItsPalettes() {
        for theme in AppTheme.all {
            #expect(ThemeSelection.palette(themeID: theme.id, dark: true).name == theme.dark.name)
            #expect(ThemeSelection.palette(themeID: theme.id, dark: false).name == theme.light.name)
        }
        #expect(
            ThemeSelection.palette(themeID: "no-such-theme", dark: true).name
                == AppTheme.fallback.dark.name)
        #expect(
            ThemeSelection.palette(themeID: nil, dark: false).name == AppTheme.fallback.light.name)
    }

    /// The system id is a choice, not a theme: it must never resolve to a palette by accident.
    @Test func theSystemChoiceIsNotInTheCatalog() {
        #expect(!AppTheme.all.contains { $0.id == ThemeSelection.systemID })
    }

    @Test func appearancePinsOnlyWhenAsked() {
        #expect(ThemeAppearance.system.pinnedDark == nil)
        #expect(ThemeAppearance.light.pinnedDark == false)
        #expect(ThemeAppearance.dark.pinnedDark == true)
        for appearance in ThemeAppearance.allCases {
            #expect(!appearance.title.isEmpty)
        }
    }

    @Test func theReportCarriesEveryTheme() {
        let report = ThemeReport.text()
        for theme in AppTheme.all {
            #expect(report.contains(theme.name))
            #expect(report.contains(theme.dark.corrected().canvas))
        }
        #expect(!report.contains("Optional("))
    }
}
