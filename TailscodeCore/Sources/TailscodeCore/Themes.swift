import Foundation

/// The colors of one appearance, named by what they mean rather than what they are: the transcript
/// canvas and its raised surfaces, the two text registers, and the handful of signal colors every
/// glyph, pill and border draws from.
///
/// Each signal slot carries exactly one meaning, because a reader decodes a colour once: `accent`
/// is motion and affirmation, `warn` is attention, `danger` is failure, `info` is the identity of
/// things the agent touched, `special` is a standing mark. Nothing shares.
///
/// A palette is *authored* in a theme's own published colors and *published* through `corrected()`,
/// which walks any slot that cannot be read on this canvas up or down in lightness until it can.
/// Every loved palette puts at least one accent under 4.5:1 on at least one of its backgrounds —
/// Solarized's are tuned for equal luminance, which on its own light base reads at 3:1 — and the
/// choice is between quoting them faithfully and being legible. This does both: the hue and chroma
/// are the theme's, only the lightness is the app's, and only where it had to be.
public struct Palette: Equatable, Sendable {
    public let name: String
    public let isDark: Bool
    public let canvas: String
    public let canvasRaised: String
    public let rule: String
    public var text: String
    /// The secondary register: idle rows, ages, output, anything that is context rather than fact.
    public var textDim: String
    /// Motion and affirmation: a running glyph, a live pill, `+` in a diff, the prompt rule.
    public var accent: String
    /// The same family, one step quieter — insert mode, notices, a gauge nowhere near its wall.
    public var accentDim: String
    /// Attention: this needs you, or this is degraded. Approvals, questions, reconnecting, a quota
    /// near its wall, a signed-out agent. Never motion.
    public var warn: String
    /// Failure and subtraction: a failed turn, an errored tool, `-` in a diff.
    public var danger: String
    /// Identity of what the agent touched: tool names, file paths, attachments, subagents, modes.
    public var info: String
    /// Standing marks on the conversation: the goal, a compaction seam, a saved chat.
    public var special: String
    public let codeBg: String
    public let subagentBg: String
    public let findHit: String
    /// Text set on a signal-filled surface — the vim badge, the jump pill, a state pill. Always the
    /// canvas itself, so a fill that reads against the canvas reads against its own ink too.
    public let onAccent: String
    /// The agents' own colours, for the quota cards that name them. Authored once and corrected per
    /// palette, which is how Claude's terracotta survives a cream canvas and xAI stays monochrome.
    public var brandClaude: String
    public var brandOpencode: String
    public var brandGrok: String
    /// The shell pane wears the theme too: sixteen ANSI colors plus its own fg/bg, because a
    /// terminal that stays black inside a Solarized window is a hole in the design. These stay
    /// exactly as published — a terminal's colours are a contract with what runs inside it, and
    /// `ls --color` is not the app's text to make readable.
    public let terminalFg: String
    public let terminalBg: String
    public let ansi: [String]

    public init(
        name: String, isDark: Bool,
        canvas: String, canvasRaised: String, rule: String,
        text: String, textDim: String,
        accent: String, accentDim: String,
        warn: String, danger: String,
        info: String, special: String,
        codeBg: String, subagentBg: String, findHit: String,
        ansi: [String],
        terminalFg: String? = nil, terminalBg: String? = nil
    ) {
        self.name = name
        self.isDark = isDark
        self.canvas = canvas
        self.canvasRaised = canvasRaised
        self.rule = rule
        self.text = text
        self.textDim = textDim
        self.accent = accent
        self.accentDim = accentDim
        self.warn = warn
        self.danger = danger
        self.info = info
        self.special = special
        self.codeBg = codeBg
        self.subagentBg = subagentBg
        self.findHit = findHit
        self.onAccent = canvas
        self.brandClaude = "#d97757"
        self.brandOpencode = "#03b000"
        self.brandGrok = isDark ? "#e8e8eb" : "#1f1f1f"
        self.terminalFg = terminalFg ?? text
        self.terminalBg = terminalBg ?? canvas
        self.ansi = ansi
    }

    /// The palette as the app actually draws it: every slot walked to its contrast floor, and only
    /// the ones that fell short moved at all.
    public func corrected() -> Palette {
        var copy = self
        func fix(_ color: String, _ ratio: Double) -> String {
            Contrast.adjusted(color, on: canvas, ratio: ratio) ?? color
        }
        copy.text = fix(text, Contrast.readable)
        copy.textDim = fix(textDim, Contrast.secondary)
        copy.accent = fix(accent, Contrast.readable)
        copy.accentDim = fix(accentDim, Contrast.readable)
        copy.warn = fix(warn, Contrast.readable)
        copy.danger = fix(danger, Contrast.readable)
        copy.info = fix(info, Contrast.readable)
        copy.special = fix(special, Contrast.readable)
        copy.brandClaude = fix(brandClaude, Contrast.readable)
        copy.brandOpencode = fix(brandOpencode, Contrast.readable)
        copy.brandGrok = fix(brandGrok, Contrast.readable)
        return copy
    }

    /// Every slot that is set as text or as a fill, with what it must clear to be read. The dim
    /// register and purely graphical marks are held to the lower bar; anything that spells out a
    /// fact is held to the higher one. `onAccent` is the canvas, so a fill is checked by the same
    /// arithmetic that checked the text.
    public var contrastContract: [(slot: String, color: String, against: String, ratio: Double)] {
        [
            ("text", text, canvas, Contrast.readable),
            ("textDim", textDim, canvas, Contrast.secondary),
            ("accent", accent, canvas, Contrast.readable),
            ("accentDim", accentDim, canvas, Contrast.readable),
            ("warn", warn, canvas, Contrast.readable),
            ("danger", danger, canvas, Contrast.readable),
            ("info", info, canvas, Contrast.readable),
            ("special", special, canvas, Contrast.readable),
            ("brandClaude", brandClaude, canvas, Contrast.readable),
            ("brandOpencode", brandOpencode, canvas, Contrast.readable),
            ("brandGrok", brandGrok, canvas, Contrast.readable),
            ("onAccent/accent", onAccent, accent, Contrast.readable),
            ("onAccent/warn", onAccent, warn, Contrast.readable),
            ("onAccent/danger", onAccent, danger, Contrast.readable),
            ("onAccent/info", onAccent, info, Contrast.readable),
            ("onAccent/special", onAccent, special, Contrast.readable),
            ("onAccent/accentDim", onAccent, accentDim, Contrast.readable),
        ]
    }
}

/// One identity in two appearances. A theme is picked once and then follows the desktop between
/// light and dark, rather than being two unrelated choices — Rosé Pine's own Dawn is what Rosé Pine
/// looks like in daylight, and pairing it with someone else's light theme was never the intent.
public struct AppTheme: Equatable, Sendable {
    public let id: String
    public let name: String
    /// One line for the picker: what this theme is, not a list of its colours.
    public let blurb: String
    public let dark: Palette
    public let light: Palette

    public func palette(dark: Bool) -> Palette { dark ? self.dark : light }

    public static let all: [AppTheme] = [
        .rosePine, .tokyoNight, .everforest, .gruvbox, .nord, .solarized, .suomi, .phosphor,
    ]

    public static let fallback = AppTheme.rosePine

    public static func named(_ id: String?) -> AppTheme {
        guard let id, let theme = all.first(where: { $0.id == id }) else { return fallback }
        return theme
    }
}

extension AppTheme {
    public static let rosePine = AppTheme(
        id: "rosepine", name: "Rosé Pine",
        blurb: Localized.text("Soho vibes — muted plum and foam, with Dawn for daylight"),
        dark: Palette(
            name: "rosepine", isDark: true,
            canvas: "#191724", canvasRaised: "#1f1d2e", rule: "#26233a",
            text: "#e0def4", textDim: "#908caa",
            accent: "#9ccfd8", accentDim: "#31748f",
            warn: "#f6c177", danger: "#eb6f92",
            info: "#c4a7e7", special: "#ebbcba",
            codeBg: "#16141f", subagentBg: "#1f1d2e", findHit: "#403d52",
            ansi: [
                "#26233a", "#eb6f92", "#31748f", "#f6c177",
                "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
                "#6e6a86", "#eb6f92", "#31748f", "#f6c177",
                "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
            ]),
        light: Palette(
            name: "rosepine-dawn", isDark: false,
            canvas: "#faf4ed", canvasRaised: "#fffaf3", rule: "#dfdad9",
            text: "#575279", textDim: "#797593",
            accent: "#56949f", accentDim: "#286983",
            warn: "#ea9d34", danger: "#b4637a",
            info: "#907aa9", special: "#d7827e",
            codeBg: "#f2e9e1", subagentBg: "#fffaf3", findHit: "#f4ede8",
            ansi: [
                "#f2e9e1", "#b4637a", "#286983", "#ea9d34",
                "#56949f", "#907aa9", "#d7827e", "#575279",
                "#9893a5", "#b4637a", "#286983", "#ea9d34",
                "#56949f", "#907aa9", "#d7827e", "#575279",
            ]))

    public static let tokyoNight = AppTheme(
        id: "tokyonight", name: "Tokyo Night",
        blurb: Localized.text("Neon over deep indigo — the city at night, and Day when it isn't"),
        dark: Palette(
            name: "tokyonight", isDark: true,
            canvas: "#1a1b26", canvasRaised: "#1f2335", rule: "#292e42",
            text: "#c0caf5", textDim: "#7a84b0",
            accent: "#9ece6a", accentDim: "#7aa2f7",
            warn: "#e0af68", danger: "#f7768e",
            info: "#bb9af7", special: "#7dcfff",
            codeBg: "#16161e", subagentBg: "#1f2335", findHit: "#3d59a1",
            ansi: [
                "#15161e", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                "#414868", "#f7768e", "#9ece6a", "#e0af68",
                "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
            ]),
        light: Palette(
            name: "tokyonight-day", isDark: false,
            canvas: "#e1e2e7", canvasRaised: "#e9e9ec", rule: "#c4c8da",
            text: "#3760bf", textDim: "#6172b0",
            accent: "#587539", accentDim: "#2e7de9",
            warn: "#8c6c3e", danger: "#f52a65",
            info: "#9854f1", special: "#007197",
            codeBg: "#d7d8de", subagentBg: "#e9e9ec", findHit: "#c4c8da",
            ansi: [
                "#e9e9ed", "#f52a65", "#587539", "#8c6c3e",
                "#2e7de9", "#9854f1", "#007197", "#6172b0",
                "#a1a6c5", "#f52a65", "#587539", "#8c6c3e",
                "#2e7de9", "#9854f1", "#007197", "#3760bf",
            ]))

    public static let everforest = AppTheme(
        id: "everforest", name: "Everforest",
        blurb: Localized.text("Low-contrast forest greens, easy on the eyes for a long session"),
        dark: Palette(
            name: "everforest", isDark: true,
            canvas: "#2d353b", canvasRaised: "#343f44", rule: "#3d484d",
            text: "#d3c6aa", textDim: "#9da9a0",
            accent: "#a7c080", accentDim: "#7fbbb3",
            warn: "#dbbc7f", danger: "#e67e80",
            info: "#d699b6", special: "#83c092",
            codeBg: "#272e33", subagentBg: "#343f44", findHit: "#4f5b58",
            ansi: [
                "#343f44", "#e67e80", "#a7c080", "#dbbc7f",
                "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
                "#4f5b58", "#e67e80", "#a7c080", "#dbbc7f",
                "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
            ]),
        light: Palette(
            name: "everforest-light", isDark: false,
            canvas: "#fdf6e3", canvasRaised: "#f4f0d9", rule: "#e6e2cc",
            text: "#5c6a72", textDim: "#829181",
            accent: "#8da101", accentDim: "#3a94c5",
            warn: "#dfa000", danger: "#f85552",
            info: "#df69ba", special: "#35a77c",
            codeBg: "#f4f0d9", subagentBg: "#f4f0d9", findHit: "#e6e2cc",
            ansi: [
                "#e0dcc7", "#f85552", "#8da101", "#dfa000",
                "#3a94c5", "#df69ba", "#35a77c", "#5c6a72",
                "#a6b0a0", "#f85552", "#8da101", "#dfa000",
                "#3a94c5", "#df69ba", "#35a77c", "#4f585e",
            ]))

    public static let gruvbox = AppTheme(
        id: "gruvbox", name: "Gruvbox",
        blurb: Localized.text("Retro warmth — earthy browns under bright, unapologetic accents"),
        dark: Palette(
            name: "gruvbox", isDark: true,
            canvas: "#282828", canvasRaised: "#32302f", rule: "#3c3836",
            text: "#ebdbb2", textDim: "#a89984",
            accent: "#b8bb26", accentDim: "#8ec07c",
            warn: "#fabd2f", danger: "#fb4934",
            info: "#d3869b", special: "#fe8019",
            codeBg: "#1d2021", subagentBg: "#32302f", findHit: "#504945",
            ansi: [
                "#282828", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#a89984",
                "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
            ]),
        light: Palette(
            name: "gruvbox-light", isDark: false,
            canvas: "#fbf1c7", canvasRaised: "#f2e5bc", rule: "#ebdbb2",
            text: "#3c3836", textDim: "#7c6f64",
            accent: "#79740e", accentDim: "#427b58",
            warn: "#b57614", danger: "#9d0006",
            info: "#8f3f71", special: "#af3a03",
            codeBg: "#f9f5d7", subagentBg: "#f2e5bc", findHit: "#ebdbb2",
            ansi: [
                "#fbf1c7", "#cc241d", "#98971a", "#d79921",
                "#458588", "#b16286", "#689d6a", "#7c6f64",
                "#928374", "#9d0006", "#79740e", "#b57614",
                "#076678", "#8f3f71", "#427b58", "#3c3836",
            ]))

    public static let nord = AppTheme(
        id: "nord", name: "Nord",
        blurb: Localized.text("Arctic blues, calm and even — Polar Night and Snow Storm"),
        dark: Palette(
            name: "nord", isDark: true,
            canvas: "#2e3440", canvasRaised: "#3b4252", rule: "#434c5e",
            text: "#eceff4", textDim: "#9099ab",
            accent: "#a3be8c", accentDim: "#81a1c1",
            warn: "#ebcb8b", danger: "#bf616a",
            info: "#b48ead", special: "#88c0d0",
            codeBg: "#272c36", subagentBg: "#3b4252", findHit: "#4c566a",
            ansi: [
                "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
            ]),
        /// Nord's Aurora is drawn for Polar Night: on Snow Storm those pastels read at 1.4:1, and
        /// letting the corrector haul them down one at a time produces six unrelated muds. So the
        /// signals here are Aurora and Frost taken to their deep end deliberately, as a family —
        /// the same hues, chosen rather than derived, and already at the floor before correction.
        light: Palette(
            name: "nord-snow", isDark: false,
            canvas: "#eceff4", canvasRaised: "#e5e9f0", rule: "#d8dee9",
            text: "#2e3440", textDim: "#4c566a",
            accent: "#4f7a3d", accentDim: "#4c6f99",
            warn: "#8a6520", danger: "#a3434e",
            info: "#8a5686", special: "#3d6e70",
            codeBg: "#e5e9f0", subagentBg: "#e5e9f0", findHit: "#d8dee9",
            ansi: [
                "#d8dee9", "#bf616a", "#a3be8c", "#ebcb8b",
                "#5e81ac", "#b48ead", "#8fbcbb", "#4c566a",
                "#aeb3bb", "#bf616a", "#a3be8c", "#ebcb8b",
                "#81a1c1", "#b48ead", "#88c0d0", "#2e3440",
            ]))

    public static let solarized = AppTheme(
        id: "solarized", name: "Solarized",
        blurb: Localized.text("Ethan Schoonover's tuned pair — the same accents on both bases"),
        dark: Palette(
            name: "solarized-dark", isDark: true,
            canvas: "#002b36", canvasRaised: "#073642", rule: "#0b4b5a",
            text: "#93a1a1", textDim: "#657b83",
            accent: "#859900", accentDim: "#268bd2",
            warn: "#b58900", danger: "#dc322f",
            info: "#2aa198", special: "#6c71c4",
            codeBg: "#01212b", subagentBg: "#073642", findHit: "#0f4b56",
            ansi: [
                "#073642", "#dc322f", "#859900", "#b58900",
                "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                "#002b36", "#cb4b16", "#586e75", "#657b83",
                "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
            ]),
        light: Palette(
            name: "solarized", isDark: false,
            canvas: "#fdf6e3", canvasRaised: "#eee8d5", rule: "#ddd6c1",
            text: "#586e75", textDim: "#93a1a1",
            accent: "#859900", accentDim: "#268bd2",
            warn: "#b58900", danger: "#dc322f",
            info: "#2aa198", special: "#6c71c4",
            codeBg: "#f5eeda", subagentBg: "#f6f0dd", findHit: "#efe3b3",
            ansi: [
                "#073642", "#dc322f", "#859900", "#b58900",
                "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                "#002b36", "#cb4b16", "#586e75", "#657b83",
                "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
            ],
            terminalFg: "#657b83"))

    /// The blue cross at home, drawn from the land rather than the flag chart. Night is kaamos
    /// over a frozen lake — the aurora carries motion, the low sun attention, lingonberry failure,
    /// ice the agent's marks, the violet of the blue moment its standing ones. Day is fresh snow
    /// under flag-blue ink, with spruce for affirmation and cloudberry for attention. Every slot
    /// is authored at its contrast floor as a family, so the corrector has nothing to move.
    public static let suomi = AppTheme(
        id: "suomi", name: "Suomi",
        blurb: Localized.text("The blue cross at home — kaamos night under aurora, fresh snow by day"),
        dark: Palette(
            name: "suomi", isDark: true,
            canvas: "#0a1522", canvasRaised: "#101f30", rule: "#1b3049",
            text: "#e9f1f9", textDim: "#8ba3bd",
            accent: "#5fd9a3", accentDim: "#3dab7d",
            warn: "#eec26b", danger: "#f0788a",
            info: "#85c7f0", special: "#bb9ce8",
            codeBg: "#071019", subagentBg: "#101f30", findHit: "#28507a",
            ansi: [
                "#16283e", "#e05c6f", "#3dab7d", "#d9a84f",
                "#5a9fd4", "#a17fd4", "#57b8c2", "#c9d8e8",
                "#3c5878", "#f0788a", "#5fd9a3", "#eec26b",
                "#85c7f0", "#bb9ce8", "#7fdbe6", "#e9f1f9",
            ]),
        light: Palette(
            name: "suomi-lumi", isDark: false,
            canvas: "#f5f8fc", canvasRaised: "#eaf0f7", rule: "#d5deea",
            text: "#1c3a5e", textDim: "#587498",
            accent: "#276b43", accentDim: "#1d5638",
            warn: "#8f5a10", danger: "#a83240",
            info: "#1f4e8c", special: "#6b4d9e",
            codeBg: "#eaf0f7", subagentBg: "#eff4f9", findHit: "#cdddf0",
            ansi: [
                "#d5deea", "#a83240", "#276b43", "#8f5a10",
                "#1f4e8c", "#6b4d9e", "#20707f", "#587498",
                "#9fb2c8", "#c14b59", "#2e8552", "#a86a14",
                "#2d64ad", "#7f5fb8", "#2a8a9c", "#1c3a5e",
            ]))

    /// The one that is ours. A coding agent answering from another machine over a private network
    /// is a terminal at the end of a long wire, so this is that terminal: a phosphor tube in the
    /// dark, and the printout it produced in the morning.
    public static let phosphor = AppTheme(
        id: "phosphor", name: "Phosphor",
        blurb: Localized.text("A green CRT at 3am, and the paper it printed by morning"),
        dark: Palette(
            name: "phosphor", isDark: true,
            canvas: "#030806", canvasRaised: "#08150f", rule: "#0e2a20",
            text: "#b8ffd0", textDim: "#5b9c76",
            accent: "#39ff88", accentDim: "#17c46a",
            warn: "#ffd166", danger: "#ff5d5d",
            info: "#67e8f9", special: "#c9a7ff",
            codeBg: "#010504", subagentBg: "#08150f", findHit: "#123d2c",
            ansi: [
                "#0e2a20", "#ff5d5d", "#39ff88", "#ffd166",
                "#67e8f9", "#c9a7ff", "#7ef0c8", "#b8ffd0",
                "#1f5a44", "#ff8080", "#7cffb0", "#ffe08a",
                "#9beeff", "#dcc4ff", "#a8ffe0", "#e6fff0",
            ]),
        light: Palette(
            name: "phosphor-paper", isDark: false,
            canvas: "#f4f1e4", canvasRaised: "#eae6d5", rule: "#d9d3bd",
            text: "#1f3a2c", textDim: "#61796b",
            accent: "#0f7a44", accentDim: "#0b5c33",
            warn: "#a06a00", danger: "#b02020",
            info: "#0d6d7a", special: "#6a3fa0",
            codeBg: "#eae6d5", subagentBg: "#eae6d5", findHit: "#ded8c0",
            ansi: [
                "#d9d3bd", "#b02020", "#0f7a44", "#a06a00",
                "#0d6d7a", "#6a3fa0", "#0e8a8a", "#1f3a2c",
                "#a89f88", "#c93c3c", "#178f55", "#b57d10",
                "#128290", "#7d4fbb", "#17a0a0", "#0f261c",
            ]))
}

/// `tailscode --themes`: the catalog as data. Colours as the app will draw them — corrected, not
/// authored — each with what it measures against its own canvas, and a mark on the ones the
/// corrector had to move. A palette is a claim about legibility; this is the claim, checkable
/// without a display or an eye.
public enum ThemeReport {
    public static func text() -> String {
        var lines: [String] = []
        for theme in AppTheme.all {
            lines.append("\(theme.name) [\(theme.id)] — \(theme.blurb)")
            for authored in [theme.dark, theme.light] {
                let palette = authored.corrected()
                lines.append(
                    "  \(palette.name)  canvas \(palette.canvas)  text \(palette.text)")
                for slot in slots(authored: authored, corrected: palette) {
                    lines.append("    " + slot)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func slots(authored: Palette, corrected: Palette) -> [String] {
        let named: [(String, String, String, Double)] = [
            ("textDim", authored.textDim, corrected.textDim, Contrast.secondary),
            ("accent", authored.accent, corrected.accent, Contrast.readable),
            ("accentDim", authored.accentDim, corrected.accentDim, Contrast.readable),
            ("warn", authored.warn, corrected.warn, Contrast.readable),
            ("danger", authored.danger, corrected.danger, Contrast.readable),
            ("info", authored.info, corrected.info, Contrast.readable),
            ("special", authored.special, corrected.special, Contrast.readable),
        ]
        return named.map { name, was, now, needs in
            let ratio = Contrast.ratio(now, on: corrected.canvas) ?? 0
            let moved = was == now ? "        " : " \(was)→"
            return name.withCString { cName in
                String(
                    format: "%-10s%@%@  %5.2f:1  (needs %.1f)", cName, moved, now, ratio, needs)
            }
        }
    }
}
