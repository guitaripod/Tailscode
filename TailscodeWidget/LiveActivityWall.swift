import SwiftUI
import TailscodeCore

/// The Agents wall's colours for a card: the theme the app is wearing, read from the shared
/// container because an extension cannot see the app's own defaults, always on its dark side —
/// the wall's rule, since a card is a screen-within-a-screen and reads as one only when it is dark.
struct CardInks {
    let palette: WallPalette

    static var current: CardInks {
        let stored = ThemeSelection.mirrored(suiteName: UsageWidgetStore.suiteName)
        return CardInks(palette: WallPalette.current(theme: AppTheme.named(stored.themeID)))
    }

    func ink(_ look: LiveActivityLook) -> Color { Color(palette.ink(for: look.state)) }

    var ground: Color { Color(palette.ground) }
    var deep: Color { Color(palette.deep) }
    var text: Color { Color(palette.text) }
    var dim: Color { Color(palette.dim) }
    var rule: Color { Color(palette.rule) }
    var needs: Color { Color(palette.needs) }
    var failed: Color { Color(palette.failed) }
    var finished: Color { Color(palette.finished) }
    var working: Color { Color(palette.working) }
    var thinking: Color { Color(palette.thinking) }
}

extension Color {
    init(_ ink: WallInk) {
        self.init(.sRGB, red: ink.red, green: ink.green, blue: ink.blue, opacity: 1)
    }
}

/// How long a change on a card takes to arrive. The platform cuts every animation on a Live
/// Activity at two seconds and runs none on an Always-On screen, so each gesture is shorter than
/// that and the caller passes the luminance it was given.
enum CardMotion {
    static func spring(_ reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.7, bounce: 0.18)
    }

    static func drift(_ reduced: Bool) -> Animation? {
        reduced ? nil : .easeInOut(duration: 1.8)
    }
}

/// The wall's orb for one card: the context ring, a lit core for work, the amber hand for a turn
/// stopped for the person, a ring with one dot for work the machine still carries, a flat line for
/// a card that has heard nothing, and a check, a cross, a square or a question for an ending —
/// the same marks a wall tile wears, drawn still, because a card changes only when news arrives.
struct CardOrb: View {
    let look: LiveActivityLook
    let ink: Color
    let warn: Color
    let fill: Double?
    let size: CGFloat
    var ultra = false
    var turn: Double = 0
    var dimmed = false

    @Environment(\.isLuminanceReduced) private var reduced

    init(model: CardModel, size: CGFloat) {
        look = model.look
        ink = model.ink
        warn = model.inks.needs
        fill = model.isLive ? model.brief?.fill : nil
        self.size = size
        ultra = model.ultra
        turn = model.phase * 2
        dimmed = model.unheard
    }

    private var ringWidth: CGFloat { max(1.5, size * 0.07) }
    private var share: Double { min(max(fill ?? 0, 0), 1) }
    /// Past 85 % the ring turns amber, the wall's sign that a compaction is near.
    private var ringInk: Color { share > 0.85 ? warn : ink }

    var body: some View {
        ZStack {
            if ultra { aura }
            Circle()
                .stroke(ink.opacity(0.18), lineWidth: ringWidth)
                .padding(ringWidth / 2)
            if fill != nil, look.mark == .orb || look.mark == .quiet || look.mark == .ask {
                Circle()
                    .trim(from: 0, to: share)
                    .stroke(ringInk, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(ringWidth / 2)
                    .animation(CardMotion.spring(reduced), value: share)
            }
            mark
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityElement()
        .accessibilityLabel(look.word)
    }

    @ViewBuilder private var mark: some View {
        switch look.mark {
        case .orb:
            core(scale: look.state == .thinking ? 0.5 : 0.56)
        case .ask:
            ZStack {
                Circle().fill(ink.opacity(0.22)).padding(size * 0.16)
                Image(systemName: look.symbol)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(ink)
                    .contentTransition(.symbolEffect(.replace))
            }
        case .background:
            ZStack {
                Circle().stroke(ink.opacity(0.85), lineWidth: ringWidth).padding(size * 0.2)
                Circle()
                    .fill(ink)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .offset(y: -size * 0.3)
                    .rotationEffect(.radians(turn))
                    .animation(CardMotion.drift(reduced), value: turn)
            }
        case .quiet:
            Capsule()
                .fill(ink)
                .frame(width: size * 0.42, height: max(2, size * 0.07))
        case .check, .cross, .stop, .unknown:
            ZStack {
                Circle().fill(ink.opacity(0.16)).padding(ringWidth)
                Image(systemName: Self.symbol(look.mark))
                    .font(.system(size: size * 0.4, weight: .heavy))
                    .foregroundStyle(ink)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    private func core(scale: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.95), ink, ink.opacity(0.35)],
                    center: UnitPoint(x: 0.38, y: 0.34), startRadius: 0, endRadius: size * scale * 0.62)
            )
            .frame(width: size * scale, height: size * scale)
            .shadow(color: ink.opacity(reduced ? 0 : 0.75), radius: size * 0.16)
    }

    private var aura: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: Ultracode.rainbowStops.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
                    center: .center),
                lineWidth: max(1.2, size * 0.05)
            )
            .rotationEffect(.radians(turn))
            .padding(-size * 0.06)
            .animation(CardMotion.drift(reduced), value: turn)
    }

    static func symbol(_ mark: LiveActivityLook.Mark) -> String {
        switch mark {
        case .check: return "checkmark"
        case .cross: return "xmark"
        case .stop: return "stop.fill"
        case .unknown: return "questionmark"
        case .orb, .ask, .background, .quiet: return "circle.fill"
        }
    }
}

/// The wall's ground under a Lock Screen card: the theme's deep colour, a glow of the state's ink
/// where the orb sits, a faint grid, and a few motes. Each update moves the motes and the glow a
/// little along their paths, so a turn that keeps sending news drifts the way the wall does, and a
/// settled card — which hears nothing — holds perfectly still.
struct CardGround: View {
    let inks: CardInks
    let ink: Color
    let phase: Double
    let seed: UInt64
    let live: Bool

    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        ZStack {
            LinearGradient(colors: [inks.ground, inks.deep], startPoint: .top, endPoint: .bottom)
            mesh
            Canvas { context, size in grid(&context, size) }
            if !reduced {
                FiniteGeometry { size in motes(in: size) }
            }
        }
        .accessibilityHidden(true)
    }

    private var glow: Double { live ? 0.32 : 0.2 }

    private var mesh: some View {
        let sway = Float(sin(phase) * 0.06)
        let lift = Float(cos(phase * 0.7) * 0.05)
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + sway, 0], [1, 0],
                [0, 0.5 + lift], [0.42 + sway, 0.55 - lift], [1, 0.5 - lift],
                [0, 1], [0.5 - sway, 1], [1, 1],
            ],
            colors: [
                ink.opacity(glow), ink.opacity(glow * 0.35), inks.deep.opacity(0),
                ink.opacity(glow * 0.45), inks.thinking.opacity(0.06), inks.deep.opacity(0),
                inks.deep.opacity(0), inks.working.opacity(0.05), ink.opacity(glow * 0.18),
            ]
        )
        .animation(CardMotion.drift(reduced), value: phase)
    }

    private func grid(_ context: inout GraphicsContext, _ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        let step: CGFloat = 18
        var path = Path()
        var x: CGFloat = step
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = step
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(inks.text.opacity(0.035)), lineWidth: 0.5)
    }

    /// A few dozen points of light, each a view of its own so the platform can carry it from where
    /// the last update left it to where this one puts it.
    private func motes(in size: CGSize) -> some View {
        ForEach(Self.motes(seed: seed), id: \.index) { mote in
            let x = (mote.x + phase * mote.speed).truncatingRemainder(dividingBy: 1)
            let y = mote.y + sin(phase * 0.5 + mote.x * 6) * 0.04
            Circle()
                .fill(ink.opacity(mote.alpha * Self.edgeFade(x)))
                .frame(width: mote.radius * 2, height: mote.radius * 2)
                .position(x: x * size.width, y: y * size.height)
                .animation(CardMotion.drift(reduced), value: phase)
        }
    }

    /// A mote fades out at the card's edges, so one that wraps from the right edge to the left
    /// crosses the card unseen rather than sliding back over it.
    static func edgeFade(_ x: Double) -> Double {
        min(1, max(0, x) * 8, max(0, 1 - x) * 8)
    }

    struct Mote {
        let index: Int
        let x: Double
        let y: Double
        let speed: Double
        let radius: CGFloat
        let alpha: Double
    }

    static func motes(seed: UInt64) -> [Mote] {
        var generator = SplitMix(seed: seed)
        return (0..<16).map { index in
            Mote(
                index: index, x: generator.unit(), y: generator.unit(),
                speed: 0.02 + generator.unit() * 0.05, radius: 0.6 + generator.unit() * 1.1,
                alpha: 0.12 + generator.unit() * 0.28)
        }
    }
}

/// A seeded generator, so a card's motes sit in the same places on every redraw and only the
/// phase moves them.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// The last minute of the agent's pulse as the wall draws it under a tile: one bar per slice,
/// oldest on the left, flat where nothing arrived.
struct CardBeat: View {
    let beats: [Int]
    let ink: Color
    let height: CGFloat

    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(beats.enumerated()), id: \.offset) { _, beat in
                Capsule()
                    .fill(ink.opacity(beat == 0 ? 0.22 : 0.45 + 0.55 * Double(beat) / Double(AgentBeat.ceiling)))
                    .frame(width: 2, height: max(1.5, height * CGFloat(beat) / CGFloat(AgentBeat.ceiling)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .animation(CardMotion.spring(reduced), value: beats)
        .accessibilityHidden(true)
    }
}

/// The thin rainbow a tile running at ultracode wears just inside its edge, turning a little with
/// every piece of news and still otherwise.
struct CardAura: View {
    let turn: Double
    let corner: CGFloat

    @Environment(\.isLuminanceReduced) private var reduced

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    colors: Ultracode.rainbowStops.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
                    center: .center, angle: .radians(turn)),
                lineWidth: 1.5
            )
            .opacity(0.85)
            .animation(CardMotion.drift(reduced), value: turn)
            .accessibilityHidden(true)
    }
}
