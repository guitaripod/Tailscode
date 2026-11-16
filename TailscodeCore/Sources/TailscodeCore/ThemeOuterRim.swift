import Foundation

extension AppTheme {
    /// A long way from the core, where the work is done by whoever is out there. Night is open
    /// space and the only light is what is lit on purpose, so every signal is a blade: the blue
    /// one is motion, the red one failure, and a diff is the two of them crossed. The gold of
    /// words that scroll away into the dark is the one that asks to be read, the green of a
    /// briefing-room display names what the agent touched, and the rare violet blade is the rare
    /// standing mark. Day is the same frontier under two suns: sand for a canvas, the ink of a
    /// worn robe, and the same five blades drained to pigment, because nothing glows at noon.
    /// The day's signals are authored to read on the raised sand as well as the canvas, which is
    /// also the shade a dune puts under the words that cross it.
    ///
    /// It is the first theme that is a place as well as a palette (`Scenery`): stars behind the
    /// transcript by night, two suns on the horizon over it by day.
    public static let outerRim = AppTheme(
        id: "outerrim", name: "Outer Rim",
        blurb: Localized.text("Blades over deep space, and two suns over the dunes by day"),
        dark: Palette(
            name: "outerrim", isDark: true,
            canvas: "#05070c", canvasRaised: "#0b0f17", rule: "#1a2130",
            text: "#dfe5ee", textDim: "#8590a3",
            accent: "#56b3ff", accentDim: "#2f7fd1",
            warn: "#ffd23f", danger: "#ff4a45",
            info: "#5fe08a", special: "#b98bff",
            codeBg: "#03050a", subagentBg: "#0a1118", findHit: "#1b3a63",
            ansi: [
                "#121722", "#ff4a45", "#5fe08a", "#ffd23f",
                "#56b3ff", "#b98bff", "#6fd9e8", "#c5cedb",
                "#3a465a", "#ff7a73", "#8cf0ab", "#ffe27a",
                "#8ccbff", "#d0b3ff", "#a0eaf4", "#f3f6fb",
            ],
            scenery: .deepSpace),
        light: Palette(
            name: "outerrim-suns", isDark: false,
            canvas: "#f4e6d0", canvasRaised: "#ecdcc2", rule: "#dccaa9",
            text: "#2b2118", textDim: "#6e5c46",
            accent: "#155cab", accentDim: "#24528f",
            warn: "#865400", danger: "#b3231c",
            info: "#226a2c", special: "#6d3fb0",
            codeBg: "#efe0c8", subagentBg: "#eee0c9", findHit: "#cfdcec",
            ansi: [
                "#dccaa9", "#b3231c", "#226a2c", "#865400",
                "#155cab", "#6d3fb0", "#17707a", "#6e5c46",
                "#a8957a", "#cf3a31", "#2f8a3b", "#a86c0a",
                "#2a7bd6", "#8457c9", "#1f8b97", "#2b2118",
            ],
            scenery: .twinSuns))
}

extension Scenery {
    /// Open space: fine dust, a scatter of ordinary stars and a handful of near ones with a halo,
    /// under two washes so faint they are only missed when they are gone. The blades are lit and
    /// what the agent delegated is a projection.
    public static let deepSpace = Scenery(
        sky: .stars(
            StarField(
                layers: [
                    StarField.Layer(
                        tile: 389, count: 52, radius: 0.45...0.7, alpha: 0.12...0.3, halo: 0,
                        seed: 0x0B17),
                    StarField.Layer(
                        tile: 631, count: 38, radius: 0.55...0.95, alpha: 0.25...0.6, halo: 0,
                        seed: 0x5EC7),
                    StarField.Layer(
                        tile: 977, count: 14, radius: 0.9...1.5, alpha: 0.5...0.72, halo: 0.4,
                        seed: 0xFA12),
                ],
                tints: ["#dfe8ff", "#dfe8ff", "#dfe8ff", "#dfe8ff", "#bcd4ff", "#fff1d6"],
                washes: [
                    SkyWash(x: 0.84, y: 0.06, reach: 0.55, color: "#2a5bd0", alpha: 0.12),
                    SkyWash(x: 0.08, y: 0.96, reach: 0.5, color: "#5a2bb0", alpha: 0.085),
                ])),
        bladeGlow: 8.5, scanLines: 0.05, castShadow: 0)

    /// Noon on the dunes: the larger sun high and its smaller, redder companion going down
    /// behind the horizon, their light falling warm across the canvas from that side, two dunes
    /// standing at its foot, and every wall casting the short hard shadow a high sun gives. The
    /// blades are ink, and nothing is projected in daylight.
    public static let twinSuns = Scenery(
        sky: .suns(
            TwinSuns(
                suns: [
                    TwinSuns.Sun(
                        x: 126, rise: 15, radius: 12, core: "#fffdf2", corona: "#ffbf66",
                        alpha: 0.98),
                    TwinSuns.Sun(
                        x: 82, rise: 5, radius: 8.5, core: "#ffd9b8", corona: "#ff8f52",
                        alpha: 0.95),
                ],
                washes: [
                    SkyWash(x: 0.1, y: 0, reach: 0.62, color: "#fff6dc", alpha: 0.55),
                    SkyWash(x: 0.5, y: 0, reach: 1.0, color: "#ffb86b", alpha: 0.07),
                ],
                dunes: [
                    TwinSuns.Dune(
                        x: 0.9, reach: 0.72, height: 250, color: "#b98a52", alpha: 0.05,
                        crest: "#fff8e6"),
                    TwinSuns.Dune(
                        x: 0.16, reach: 0.86, height: 330, color: "#a8743a", alpha: 0.085,
                        crest: "#fff8e6"),
                ])),
        bladeGlow: 0, scanLines: 0, castShadow: 0.07)
}
