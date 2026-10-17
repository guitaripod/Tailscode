import ActivityKit
import SwiftUI
import TailscodeCore
import WidgetKit

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
            LockScreenView(
                state: context.state, title: context.attributes.sessionTitle,
                serverName: context.attributes.serverName, isStale: context.isStale
            )
            .activitySystemActionForegroundColor(.primary)
                .widgetURL(sessionURL(context))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HeadIcon(state: state, width: 38, dimmed: staleDim(context))
                        .padding(.leading, 4)
                        .widgetURL(sessionURL(context))
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandTitle(
                        state: state, title: context.attributes.sessionTitle,
                        isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedView(state: state, isStale: context.isStale)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandFoot(state: state, serverName: context.attributes.serverName)
                }
            } compactLeading: {
                Image(systemName: state.faceSymbol)
                    .font(.caption2)
                    .foregroundStyle(state.faceTone.cardColor.opacity(staleDim(context) ? 0.4 : 1))
                    .accessibilityLabel(state.line)
            } compactTrailing: {
                if state.isWaitingOnYou {
                    Image(systemName: state.faceSymbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.faceTone.cardColor)
                        .accessibilityLabel(state.line)
                } else if let endedAt = state.endedAt {
                    FrozenClock(startedAt: state.startedAt, endedAt: endedAt)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.faceTone.cardColor)
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
                    .foregroundStyle(state.faceTone.cardColor.opacity(staleDim(context) ? 0.4 : 1))
                    .accessibilityLabel(state.line)
            }
        }
    }
}

