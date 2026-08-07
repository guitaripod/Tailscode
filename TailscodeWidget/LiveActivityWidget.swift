import ActivityKit
import SwiftUI
import TailscodeCore
import WidgetKit

extension ChatActivityAttributes.ContentState.Phase {
    var isTerminal: Bool { self == .done || self == .error }

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
    /// The app computes the face where Core lives — a running shell wears the terminal here
    /// exactly as it does in the transcript — and the widget only draws what it was handed.
    var faceSymbol: String { symbol ?? phase.fallbackSymbol }

    var faceTone: ActivityTone {
        tone.flatMap(ActivityTone.init(rawValue:)) ?? phase.fallbackTone
    }
}

extension ActivityTone {
    /// The same four meanings every other badge resolves, in the island's own colours — no theme
    /// reaches the Lock Screen.
    var color: Color {
        switch self {
        case .live: return .green
        case .attention: return .orange
        case .danger: return .red
        case .quiet: return .secondary
        }
    }
}

private func sessionURL(_ context: ActivityViewContext<ChatActivityAttributes>) -> URL? {
    URL(string: "tailscode://session/\(context.attributes.sessionID)")
}

/// Terminal states arrive with staleDate == now on purpose, so a stale look
/// only applies while a turn is still (supposedly) running.
private func staleDim(_ context: ActivityViewContext<ChatActivityAttributes>) -> Bool {
    context.isStale && !context.state.phase.isTerminal
}

struct LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(sessionURL(context))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(state: state, size: 36)
                        .padding(.leading, 4)
                        .widgetURL(sessionURL(context))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title ?? context.attributes.sessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        StatusText(state: state, isStale: context.isStale)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedView(state: state, isStale: context.isStale)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        if let tool = state.lastTool, !state.phase.isTerminal {
                            Label(
                                tool,
                                systemImage: state.phase == .tool
                                    ? state.faceSymbol : "wrench.and.screwdriver"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        if state.toolCount > 0 {
                            Text(String(localized: "\(state.toolCount) tools"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Label(context.attributes.serverName, systemImage: "server.rack")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.faceSymbol)
                    .font(.caption2)
                    .foregroundStyle(state.faceTone.color.opacity(staleDim(context) ? 0.4 : 1))
                    .accessibilityLabel(state.phase.label)
            } compactTrailing: {
                if state.phase.isTerminal || state.phase == .approval {
                    Image(systemName: state.faceSymbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.faceTone.color)
                        .accessibilityLabel(state.phase.label)
                } else if context.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "Waiting for updates"))
                } else {
                    Text(state.startedAt, style: .timer)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 44)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: state.faceSymbol)
                    .font(.caption2)
                    .foregroundStyle(state.faceTone.color.opacity(staleDim(context) ? 0.4 : 1))
                    .accessibilityLabel(state.phase.label)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ChatActivityAttributes>

    var body: some View {
        let state = context.state
        HStack(spacing: 12) {
            PhaseIcon(state: state, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.title ?? context.attributes.sessionTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                StatusText(state: state, isStale: context.isStale)
                    .font(.caption)
                    .lineLimit(1)
                if let tool = state.lastTool, !state.phase.isTerminal {
                    Label(
                        tool,
                        systemImage: state.phase == .tool
                            ? state.faceSymbol : "wrench.and.screwdriver"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                ElapsedView(state: state, isStale: context.isStale)
                Text(context.attributes.serverName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }
}

private struct PhaseIcon: View {
    let state: ChatActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(state.faceTone.color.opacity(0.18))
            Image(systemName: state.faceSymbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(state.faceTone.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct StatusText: View {
    let state: ChatActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if isStale && !state.phase.isTerminal {
            Text(String(localized: "Waiting for updates…"))
                .foregroundStyle(.secondary)
        } else {
            Text(state.statusText)
                .foregroundStyle(state.faceTone.color)
        }
    }
}

private struct ElapsedView: View {
    let state: ChatActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if state.phase.isTerminal {
            Text(
                timerInterval: state.startedAt...(state.endedAt ?? state.startedAt),
                pauseTime: state.endedAt ?? state.startedAt,
                countsDown: false
            )
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(state.faceTone.color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: 56)
            .multilineTextAlignment(.trailing)
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
