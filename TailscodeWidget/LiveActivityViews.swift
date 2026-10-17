import SwiftUI
import TailscodeCore

extension ChatActivityAttributes.ContentState.Phase {
    var label: String {
        switch self {
        case .thinking: return String(localized: "Thinking")
        case .tool: return String(localized: "Running tool")
        case .responding: return String(localized: "Writing")
        case .approval: return String(localized: "Needs approval")
        case .done: return String(localized: "Done")
        case .error: return String(localized: "Failed")
        }
    }

    /// The face an activity started by an older app process falls back to, spelled in the same
    /// vocabulary Core authors for these states.
    var fallbackSymbol: String {
        switch self {
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver"
        case .responding: return "text.alignleft"
        case .approval: return "hand.raised"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var fallbackTone: ActivityTone {
        switch self {
        case .thinking, .tool, .responding, .done: return .live
        case .approval: return .attention
        case .error: return .danger
        }
    }
}

extension ChatActivityAttributes.ContentState {
    /// Which thing the card is saying, when its sender named it — which every sender now does,
    /// the server included, so a push arriving while the phone slept reads in this phone's
    /// language rather than the server's.
    var reading: LiveActivityDetail? { detail.flatMap(LiveActivityDetail.init(rawValue:)) }

    var line: String {
        guard let reading else { return statusText }
        return reading.line(
            tool: isSettled ? nil : lastTool, toolCount: toolCount, background: background ?? 0)
    }

    /// The app computes the face where Core lives — a running shell wears the terminal here
    /// exactly as it does in the transcript — and a card whose sender did not say is given the
    /// face its detail wears, then its phase's.
    var faceSymbol: String {
        symbol ?? reading?.face(tool: isSettled ? nil : lastTool).symbol ?? phase.fallbackSymbol
    }

    var faceTone: ActivityTone {
        tone.flatMap(ActivityTone.init(rawValue:))
            ?? reading?.face(tool: isSettled ? nil : lastTool).tone ?? phase.fallbackTone
    }

    /// The head to draw: the one the app sent, or the plain one with an eye in the card's tone.
    var glyphPlan: NeuralGlyphPlan {
        glyph?.plan()
            ?? .plain(eyeTone: glyph?.eyeTone ?? NeuralTone(rawValue: faceTone.rawValue) ?? .quiet)
    }

    /// Stopped for the person — a live approval or a question the turn ended on. The island says
    /// so with the face rather than a clock, because a clock would read as work.
    var isWaitingOnYou: Bool { phase == .approval }
}

extension ActivityTone {
    /// The same four meanings every other badge resolves, in the island's own colours — no theme
    /// reaches the Lock Screen.
    var cardColor: Color {
        switch self {
        case .live: return .green
        case .attention: return .orange
        case .danger: return .red
        case .quiet: return .secondary
        }
    }
}

/// The card on the Lock Screen, written over what it shows rather than over the system's context
/// so the same view can be looked at in the app.
struct LockScreenView: View {
    let state: ChatActivityAttributes.ContentState
    let title: String
    let serverName: String
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            HeadIcon(state: state, width: 44, dimmed: isStale && !state.isSettled)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title ?? title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                StatusText(state: state, isStale: isStale)
                    .font(.caption)
                    .lineLimit(1)
                if let endedAt = state.endedAt {
                    EndedAgo(endedAt: endedAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let tool = state.lastTool {
                    ToolLabel(tool: tool, state: state)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                ElapsedView(state: state, isStale: isStale)
                Text(serverName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }
}

/// The turn's head where the card used to wear a tinted circle: on the Lock Screen and in the
/// expanded island. A card whose sender sent no counts draws the plain head with an eye in the
/// tone the card already carries, which is all that sender said.
struct HeadIcon: View {
    let state: ChatActivityAttributes.ContentState
    let width: CGFloat
    let dimmed: Bool

    var body: some View {
        NeuralGlyphView(plan: state.glyphPlan, width: width, dimmed: dimmed)
    }
}

struct StatusText: View {
    let state: ChatActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale && !state.isSettled {
            Text(String(localized: "Waiting for updates…"))
                .foregroundStyle(.secondary)
        } else {
            Text(state.line)
                .foregroundStyle(state.faceTone.cardColor)
        }
    }
}

/// The tool the turn last reached for. While that tool is out on the machine the line above
/// already names it, so it wears the tool's own face; otherwise it is context, and says so.
struct ToolLabel: View {
    let tool: String
    let state: ChatActivityAttributes.ContentState

    var body: some View {
        Label(
            tool,
            systemImage: state.phase == .tool ? state.faceSymbol : "wrench.and.screwdriver"
        )
        .lineLimit(1)
    }
}

/// How long ago the turn ended, in the reader's language and kept current by the system — the
/// line a card that has been waiting to be read owes whoever finally reads it.
struct EndedAgo: View {
    let endedAt: Date

    var body: some View {
        Text(
            .currentDate,
            format: .reference(to: endedAt, allowedFields: [.day, .hour, .minute], maxFieldCount: 1)
        )
        .lineLimit(1)
    }
}

/// The turn's clock, stopped where the turn stopped.
struct FrozenClock: View {
    let startedAt: Date
    let endedAt: Date

    var body: some View {
        Text(
            timerInterval: startedAt...max(startedAt, endedAt),
            pauseTime: max(startedAt, endedAt),
            countsDown: false
        )
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
    }
}

struct ElapsedView: View {
    let state: ChatActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let endedAt = state.endedAt {
            FrozenClock(startedAt: state.startedAt, endedAt: endedAt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state.faceTone.cardColor)
                .frame(maxWidth: 56)
        } else if isStale {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Waiting for updates"))
        } else {
            Text(state.startedAt, style: .timer)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: 56)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The expanded island's centre: the conversation's name over what the turn is doing.
struct IslandTitle: View {
    let state: ChatActivityAttributes.ContentState
    let title: String
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title ?? title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            StatusText(state: state, isStale: isStale)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

/// The expanded island's foot: what the turn last reached for, or how long ago it ended, with the
/// count and the machine.
struct IslandFoot: View {
    let state: ChatActivityAttributes.ContentState
    let serverName: String

    var body: some View {
        HStack(spacing: 6) {
            if let endedAt = state.endedAt {
                EndedAgo(endedAt: endedAt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let tool = state.lastTool {
                ToolLabel(tool: tool, state: state)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.toolCount > 0, !state.isSettled {
                Text(String(localized: "\(state.toolCount) tools"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Label(serverName, systemImage: "server.rack")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
    }
}
