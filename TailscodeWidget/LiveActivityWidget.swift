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
}

private func sessionURL(_ context: ActivityViewContext<ChatActivityAttributes>) -> URL? {
    URL(string: "tailscode://session/\(context.attributes.sessionID)")
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
                        Text(state.statusText)
                            .font(.caption)
                            .foregroundStyle(state.phase.tint)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedView(state: state)
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
                    .foregroundStyle(state.phase.tint)
            } compactTrailing: {
                if state.phase.isTerminal || state.phase == .approval {
                    Image(systemName: state.phase == .approval ? "exclamationmark" : state.phase.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.phase.tint)
                } else {
                    Text(state.startedAt, style: .timer)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            } minimal: {
                Image(systemName: state.phase.symbol)
                    .font(.caption2)
                    .foregroundStyle(state.phase.tint)
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
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(state.phase.tint)
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
                ElapsedView(state: state)
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
    }
}

private struct ElapsedView: View {
    let state: ChatActivityAttributes.ContentState

    var body: some View {
        if state.phase.isTerminal {
            Text(
                timerInterval: state.startedAt...(state.endedAt ?? state.startedAt),
                pauseTime: state.endedAt ?? state.startedAt
            )
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(state.phase.tint)
            .frame(maxWidth: 56)
            .multilineTextAlignment(.trailing)
        } else {
            Text(state.startedAt, style: .timer)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: 56)
                .multilineTextAlignment(.trailing)
        }
    }
}
