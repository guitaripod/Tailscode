import ActivityKit
import SwiftUI
import TailscodeCore
import WidgetKit

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

    /// Stopped for the person — a live approval or a question the turn ended on. The island says
    /// so with the face rather than a clock, because a clock would read as work.
    var isWaitingOnYou: Bool { phase == .approval }
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

/// A settled card has no stale date, so a stale look only applies while a turn is still
/// (supposedly) running.
private func staleDim(_ context: ActivityViewContext<ChatActivityAttributes>) -> Bool {
    context.isStale && !context.state.isSettled
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
                    .accessibilityLabel(state.line)
            } compactTrailing: {
                if state.isWaitingOnYou {
                    Image(systemName: state.faceSymbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.faceTone.color)
                        .accessibilityLabel(state.line)
                } else if let endedAt = state.endedAt {
                    FrozenClock(startedAt: state.startedAt, endedAt: endedAt)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.faceTone.color)
                        .frame(maxWidth: 44)
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
                    .accessibilityLabel(state.line)
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
        if isStale && !state.isSettled {
            Text(String(localized: "Waiting for updates…"))
                .foregroundStyle(.secondary)
        } else {
            Text(state.line)
                .foregroundStyle(state.faceTone.color)
        }
    }
}

/// The tool the turn last reached for. While that tool is out on the machine the line above
/// already names it, so it wears the tool's own face; otherwise it is context, and says so.
private struct ToolLabel: View {
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
private struct EndedAgo: View {
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
private struct FrozenClock: View {
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

private struct ElapsedView: View {
    let state: ChatActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if let endedAt = state.endedAt {
            FrozenClock(startedAt: state.startedAt, endedAt: endedAt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state.faceTone.color)
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
