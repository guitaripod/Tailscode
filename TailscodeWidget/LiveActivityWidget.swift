import ActivityKit
import SwiftUI
import WidgetKit

struct LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.serverName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(context.state.status)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let tool = context.state.lastTool {
                        Text(tool)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let tool = context.state.lastTool {
                        Text(tool)
                            .font(.caption2)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles")
                    .font(.caption2)
            } compactTrailing: {
                Text(context.state.status)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "sparkles")
            }
        }
    }
}
