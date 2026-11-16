import SwiftUI
import TailscodeCore
import WidgetKit

/// The card wherever the system shows the Lock Screen presentation: the Lock Screen and StandBy in
/// the size the person chose, the Smart Stack on Apple Watch and the CarPlay Dashboard in the
/// small family's own layout.
struct ActivityCardView: View {
    let model: CardModel

    @Environment(\.activityFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .small: SmallCard(model: model)
            default: LockScreenCard(model: model, size: LiveActivitySettings.size)
            }
        }
        .activityBackgroundTint(model.inks.deep)
        .activitySystemActionForegroundColor(model.inks.text)
    }
}

/// The card on Apple Watch and in CarPlay: the orb, the conversation and its line, and the clock.
struct SmallCard: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CardOrb(model: model, size: 22)
                Text(model.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.inks.text)
                    .lineLimit(1)
                Spacer(minLength: 2)
                CardClock(model: model, font: .caption2.weight(.semibold))
            }
            Text(model.headline)
                .font(.footnote.weight(.medium))
                .foregroundStyle(model.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(8)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// The compact island's leading mark and the minimal one: a small lit dot in the state's ink
/// wearing the face's symbol while the turn runs and the ending's mark once it ends.
struct IslandDot: View {
    let model: CardModel
    let size: CGFloat

    private var symbol: String {
        switch model.look.mark {
        case .check, .cross, .stop, .unknown: return CardOrb.symbol(model.look.mark)
        case .quiet: return "minus"
        case .orb, .ask, .background: return model.look.symbol
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [model.ink.opacity(0.95), model.ink.opacity(0.55)],
                        center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.7))
            if model.ultra {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: Ultracode.rainbowStops.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
                            center: .center),
                        lineWidth: 1.5)
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(model.inks.deep)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .opacity(model.unheard ? 0.45 : 1)
        .accessibilityElement()
        .accessibilityLabel("\(model.look.word), \(model.state.line)")
    }
}

/// The compact island's trailing side: the clock while the turn runs, the stopped clock once it
/// ended, the face while it waits on the person. Where iOS 27 draws the island narrow — a phone on
/// its side, an iPhone Duo, several cards at once — there is no room for it and the leading dot
/// says it all.
struct IslandTrailing: View {
    let model: CardModel

    var body: some View {
        if #available(iOS 27.0, *) {
            NarrowAwareTrailing(model: model)
        } else {
            IslandClock(model: model)
        }
    }
}

@available(iOS 27.0, *)
private struct NarrowAwareTrailing: View {
    let model: CardModel

    @Environment(\.isDynamicIslandLimitedInWidth) private var limited

    var body: some View {
        if limited {
            EmptyView()
        } else {
            IslandClock(model: model)
        }
    }
}

struct IslandClock: View {
    let model: CardModel

    var body: some View {
        if model.state.isWaitingOnYou {
            Image(systemName: model.look.symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(model.ink)
                .accessibilityLabel(model.state.line)
        } else if let endedAt = model.state.endedAt {
            FrozenClock(startedAt: model.state.startedAt, endedAt: endedAt)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(model.ink)
                .frame(maxWidth: 44)
        } else if model.unheard {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(model.inks.dim)
                .accessibilityLabel(String(localized: "Waiting for updates"))
        } else {
            Text(timerInterval: model.state.startedAt...Date.distantFuture, countsDown: false)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: 44)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(model.quietSince == nil ? model.inks.text.opacity(0.8) : model.ink)
        }
    }
}

/// The expanded island's centre: the conversation's name over the state's word, the machine and
/// the model.
struct IslandTitle: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 4) {
                CardWord(model: model)
                if let modelWord = model.brief?.modelWord {
                    Text("·").foregroundStyle(model.inks.dim)
                    Text(modelWord).foregroundStyle(model.inks.dim).lineLimit(1)
                }
            }
            .font(.caption2)
        }
        .padding(.top, 4)
    }
}

/// The expanded island's foot — what it opens on when a turn ends with the island set to open:
/// the line in large type, then what it waits on, how it ended, or its latest step, over the pulse.
struct IslandBottom: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeadline(model: model, font: .title3.weight(.semibold), lines: 2, tinted: false)
            if let lead = model.askLead, let ask = model.ask {
                CardAsk(lead: lead, ask: ask, ink: model.ink, lines: 2)
            } else if model.state.isSettled {
                if let said = model.said {
                    Text("\u{201C}\(said)\u{201D}")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }
            } else if let plan = model.brief?.plan {
                CardPlan(plan: plan, ink: model.ink, inks: model.inks)
            } else {
                CardSteps(steps: model.steps(1), inks: model.inks, ink: model.ink)
            }
            CardFoot(model: model, saysWords: false)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .environment(\.colorScheme, .dark)
    }
}
