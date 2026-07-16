import ActivityKit
import SwiftUI
import WidgetKit

extension ChatActivityAttributes.ContentState.Phase {
    var symbol: String {
        switch self {
        case .thinking: return "sparkles"
        case .tool: return "wrench.and.screwdriver.fill"
        case .responding: return "text.cursor"
        case .approval: return "hand.raised.fill"
        case .done: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .thinking: return .blue
        case .tool: return .purple
        case .responding: return .teal
        case .approval: return .orange
        case .done: return .green
        case .error: return .red
        }
    }

    var isTerminal: Bool { self == .done || self == .error }

    var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .tool: return "Running tool"
        case .responding: return "Writing"
        case .approval: return "Needs approval"
        case .done: return "Done"
        case .error: return "Failed"
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
                    PhaseIcon(phase: state.phase, size: 36)
                        .padding(.leading, 4)
                        .widgetURL(sessionURL(context))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sessionTitle)
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
                            Label(tool, systemImage: "terminal")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if state.toolCount > 0 {
                            Text("\(state.toolCount) tool\(state.toolCount == 1 ? "" : "s")")
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
                Image(systemName: state.phase.symbol)
                    .font(.caption2)
                    .foregroundStyle(state.phase.tint.opacity(staleDim(context) ? 0.4 : 1))
                    .accessibilityLabel(state.phase.label)
            } compactTrailing: {
                if state.phase.isTerminal || state.phase == .approval {
                    Image(systemName: state.phase == .approval ? "exclamationmark" : state.phase.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.phase.tint)
                        .accessibilityLabel(state.phase.label)
                } else if context.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Waiting for updates")
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
                Image(systemName: state.phase.symbol)
                    .font(.caption2)
                    .foregroundStyle(state.phase.tint.opacity(staleDim(context) ? 0.4 : 1))
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
            PhaseIcon(phase: state.phase, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.sessionTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                StatusText(state: state, isStale: context.isStale)
                    .font(.caption)
                    .lineLimit(1)
                if let tool = state.lastTool, !state.phase.isTerminal {
                    Label(tool, systemImage: "terminal")
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
    let phase: ChatActivityAttributes.ContentState.Phase
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(phase.tint.opacity(0.18))
            Image(systemName: phase.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(phase.tint)
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
            Text("Waiting for updates\u{2026}")
                .foregroundStyle(.secondary)
        } else {
            Text(state.statusText)
                .foregroundStyle(state.phase.tint)
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
            .foregroundStyle(state.phase.tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: 56)
            .multilineTextAlignment(.trailing)
        } else if isStale {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting for updates")
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
