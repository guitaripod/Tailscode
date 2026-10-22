import Foundation

extension CardStyle {
    /// The poster look of a shared turn: a black-green canvas and phosphor ink, authored for the
    /// head to sit on. Not part of ``CardStyle/all``, which is the analytics card's menu.
    public static let neural = CardStyle(
        id: "neural", name: Localized.text("Megatron"),
        tagline: Localized.text("Black-green with phosphor ink"),
        authored: .init(
            canvas: "#04120b", canvasEnd: "#020504", text: "#d3f7e0", textDim: "#7fae93",
            accent: "#39ff88", info: "#6fd6ea", warn: "#7ff0c8", special: "#b79cff"))
}

/// A turn as a poster, laid out in pure geometry the way ``AnalyticsShare/Card`` is, so three
/// toolkits paint the same picture: the head as the hero, the numbers the transcript can prove,
/// the question that started it, and nothing that is an estimate. Logical points at 1x.
public enum NeuralShare {
    /// The two looks a poster is offered in: the app's own theme, and the poster look.
    public static let looks: [CardStyle] = [.app, .neural]

    /// Which of the style's colours a mark wears; resolved through ``Card/color(_:)``.
    public enum Slot: Sendable, Hashable {
        case text, textDim, accent, info, warn, special, raised, rule
    }

    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxY: Double { y + height }
        public var maxX: Double { x + width }
    }

    public struct FontRole: Sendable, Equatable {
        public var size: Double
        public var bold: Bool
        public var tracking: Double

        public init(_ size: Double, bold: Bool = false, tracking: Double = 0) {
            self.size = size
            self.bold = bold
            self.tracking = tracking
        }
    }

    public enum Alignment: Sendable, Equatable {
        case leading, trailing
    }

    /// A run of text in a box: the painter sets it in monospace at `font`, truncating its last
    /// line to `maxLines` rather than growing past the rect.
    public struct Label: Sendable, Equatable {
        public var text: String
        public var rect: Rect
        public var font: FontRole
        public var slot: Slot
        public var alignment: Alignment
        public var maxLines: Int

        public init(
            _ text: String, _ rect: Rect, _ font: FontRole, _ slot: Slot,
            alignment: Alignment = .leading, maxLines: Int = 1
        ) {
            self.text = text
            self.rect = rect
            self.font = font
            self.slot = slot
            self.alignment = alignment
            self.maxLines = maxLines
        }
    }

    public struct Run: Sendable, Equatable {
        public var text: String
        public var slot: Slot
    }

    /// One zone's row: its name, a track, a bar as long as its share of the busiest zone, and
    /// the count.
    public struct Meter: Sendable, Equatable {
        public var zone: NeuralZone
        public var count: Int
        public var share: Double
        public var slot: Slot
        public var label: Label
        public var track: Rect
        public var bar: Rect
        public var value: Label
    }

    public struct Quote: Sendable, Equatable {
        public var rule: Rect
        public var label: Label
    }

    /// Logical points at 1x. Clients multiply by a scale factor when rasterising.
    public struct Card: Sendable, Equatable {
        public static let width: Double = 1080
        public static let height: Double = 1350
        public static let pad: Double = 56
        public static let corner: Double = 36
        public static let contentWidth: Double = width - pad * 2

        public static let brandSize: Double = 22
        public static let brandHeight: Double = 28
        public static let heroWidth: Double = 968
        public static let heroHeight: Double = 590
        public static let heroGap: Double = 22
        public static let countSize: Double = 96
        public static let countGap: Double = 20
        public static let captionSize: Double = 34
        public static let captionGap: Double = 22
        public static let subSize: Double = 26
        public static let subHeight: Double = 34
        public static let subGap: Double = 6
        public static let meterGap: Double = 22
        public static let meterSize: Double = 24
        public static let meterHeight: Double = 30
        public static let meterSpacing: Double = 9
        public static let meterLabelWidth: Double = 150
        public static let meterValueWidth: Double = 60
        public static let meterColumnGap: Double = 16
        public static let meterTrackHeight: Double = 18
        public static let meterMinimumShare: Double = 0.03
        public static let quoteGap: Double = 24
        public static let quoteSize: Double = 23
        public static let quoteLeading: Double = 1.45
        public static let quoteRule: Double = 6
        public static let quoteInset: Double = 26
        public static let quoteLimit: Int = 90
        public static let quoteLines: Int = 2
        public static let footSize: Double = 20
        public static let footHeight: Double = 24
        public static let glyphWidth: Double = 0.6

        public let palette: AnalyticsShare.Palette
        public let brand: Label
        public let tag: Label
        public let hero: Rect
        public let count: Label
        public let caption: Label
        public let sub: [Run]
        public let subRect: Rect?
        public let meters: [Meter]
        public let quote: Quote?
        public let foot: Label
        public let footTag: Label
        /// The lowest point of anything above the footer; the poster holds the footer to the
        /// bottom edge and the space between is air.
        public let contentBottom: Double

        public func color(_ slot: Slot) -> String {
            switch slot {
            case .text: return palette.text
            case .textDim: return palette.textDim
            case .accent: return palette.accent
            case .info: return palette.info
            case .warn: return palette.warn
            case .special: return palette.special
            case .raised: return palette.raised
            case .rule: return palette.rule
            }
        }

        public static func make(
            turn: NeuralTurn, prompt: String?, style: CardStyle = .app, dark: Bool = true,
            now: Date = Date()
        ) -> Card {
            let line = NeuralReading.line(for: turn, now: now)
            return Card(
                palette: style.palette(dark: dark), turn: turn, line: line, prompt: prompt)
        }

        init(palette: AnalyticsShare.Palette, turn: NeuralTurn, line: NeuralReading.Line, prompt: String?) {
            self.palette = palette
            let pad = Card.pad
            var y = pad

            brand = Label(
                "TAILSCODE", Rect(pad, y, Card.contentWidth / 2, Card.brandHeight),
                FontRole(Card.brandSize, tracking: 0.3), .accent)
            tag = Label(
                Localized.text("ONE TURN"),
                Rect(pad + Card.contentWidth / 2, y, Card.contentWidth / 2, Card.brandHeight),
                FontRole(Card.brandSize, tracking: 0.2), .textDim, alignment: .trailing)
            y += Card.brandHeight + Card.heroGap

            hero = Rect(pad, y, Card.heroWidth, Card.heroHeight)
            y += Card.heroHeight + Card.countGap

            let number = String(line.tools)
            let numberWidth = Double(number.count) * Card.countSize * Card.glyphWidth
            count = Label(
                number, Rect(pad, y, numberWidth, Card.countSize),
                FontRole(Card.countSize, bold: true), .text)
            let captionText = Card.captionText(tools: line.tools, duration: line.duration)
            let captionX = pad + numberWidth + Card.captionGap
            let captionHeight = Card.captionSize * 1.2
            caption = Label(
                captionText,
                Rect(
                    captionX, y + Card.countSize - captionHeight - 6,
                    Card.width - pad - captionX, captionHeight),
                FontRole(Card.captionSize), .textDim)
            y += Card.countSize

            var runs: [Run] = []
            if let tally = line.tally { runs.append(Run(text: tally, slot: .accent)) }
            let rest = [line.failure, line.notes, line.thoughts].compactMap { $0 }
            if !rest.isEmpty {
                let prefix = runs.isEmpty ? "" : " \u{00B7} "
                runs.append(Run(text: prefix + rest.joined(separator: " \u{00B7} "), slot: .textDim))
            }
            sub = runs
            if runs.isEmpty {
                subRect = nil
            } else {
                y += Card.subGap
                subRect = Rect(pad, y, Card.contentWidth, Card.subHeight)
                y += Card.subHeight
            }

            y += Card.meterGap
            var zoneCounts = [Int](repeating: 0, count: NeuralZone.allCases.count)
            for step in turn.steps { zoneCounts[step.zone.rawValue] += 1 }
            let busiest = zoneCounts.max() ?? 0
            let trackX = pad + Card.meterLabelWidth + Card.meterColumnGap
            let trackWidth = Card.contentWidth - Card.meterLabelWidth - Card.meterValueWidth
                - Card.meterColumnGap * 2
            let valueX = pad + Card.contentWidth - Card.meterValueWidth
            var built: [Meter] = []
            for zone in NeuralZone.allCases {
                let n = zoneCounts[zone.rawValue]
                let share = busiest > 0 ? max(Double(n) / Double(busiest), n > 0 ? Card.meterMinimumShare : 0) : 0
                let slot = Card.slot(for: zone)
                let trackY = y + (Card.meterHeight - Card.meterTrackHeight) / 2
                built.append(
                    Meter(
                        zone: zone, count: n, share: share, slot: slot,
                        label: Label(
                            zone.label, Rect(pad, y, Card.meterLabelWidth, Card.meterHeight),
                            FontRole(Card.meterSize), slot),
                        track: Rect(trackX, trackY, trackWidth, Card.meterTrackHeight),
                        bar: Rect(trackX, trackY, trackWidth * share, Card.meterTrackHeight),
                        value: Label(
                            String(n), Rect(valueX, y, Card.meterValueWidth, Card.meterHeight),
                            FontRole(Card.meterSize), .text, alignment: .trailing)))
                y += Card.meterHeight + Card.meterSpacing
            }
            meters = built
            y -= Card.meterSpacing

            if let text = Card.quoteText(prompt) {
                y += Card.quoteGap
                let lines = Card.quoteLineCount(text)
                let height = Double(lines) * Card.quoteSize * Card.quoteLeading
                quote = Quote(
                    rule: Rect(pad, y, Card.quoteRule, height),
                    label: Label(
                        text,
                        Rect(
                            pad + Card.quoteInset, y, Card.contentWidth - Card.quoteInset, height),
                        FontRole(Card.quoteSize), .textDim, maxLines: lines))
                y += height
            } else {
                quote = nil
            }
            contentBottom = y

            let footY = Card.height - pad - Card.footHeight
            foot = Label(
                Localized.text("counted from the transcript"),
                Rect(pad, footY, Card.contentWidth * 0.7, Card.footHeight),
                FontRole(Card.footSize), .textDim)
            footTag = Label(
                "tailscode",
                Rect(pad + Card.contentWidth * 0.7, footY, Card.contentWidth * 0.3, Card.footHeight),
                FontRole(Card.footSize), .textDim, alignment: .trailing)
        }

        /// The tone each zone's meter wears.
        public static func slot(for zone: NeuralZone) -> Slot {
            switch zone {
            case .think: return .text
            case .sense: return .info
            case .act: return .accent
            case .shell: return .special
            case .delegate: return .textDim
            case .say: return .warn
            }
        }

        /// The prompt's first `quoteLimit` characters on one run, cut with an ellipsis; nil for
        /// a turn with no words to quote.
        public static func quoteText(_ prompt: String?) -> String? {
            guard let prompt else { return nil }
            let collapsed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty else { return nil }
            guard collapsed.count > quoteLimit else { return collapsed }
            return String(collapsed.prefix(quoteLimit)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }

        /// How many lines the quote is set on, estimated from its length so every client wraps
        /// to the same count.
        public static func quoteLineCount(_ text: String) -> Int {
            let capacity = (contentWidth - quoteInset) / (quoteSize * glyphWidth)
            let needed = Int((Double(text.count) / capacity).rounded(.up))
            return min(max(1, needed), quoteLines)
        }

        public static func captionText(tools: Int, duration: String?) -> String {
            switch (tools == 1, duration) {
            case (true, let duration?): return Localized.text("tool in %@", duration)
            case (false, let duration?): return Localized.text("tools in %@", duration)
            case (true, nil): return Localized.text("tool")
            case (false, nil): return Localized.text("tools")
            }
        }
    }
}
