import ActivityKit
import SwiftUI
import TailscodeCore
import WidgetKit

private func sessionURL(_ context: ActivityViewContext<ChatActivityAttributes>) -> URL? {
    URL(string: "tailscode://session/\(context.attributes.sessionID)")
}

private func card(_ context: ActivityViewContext<ChatActivityAttributes>) -> CardModel {
    CardModel(
        state: context.state, title: context.attributes.sessionTitle,
        server: context.attributes.serverName, isStale: context.isStale,
        seedKey: context.attributes.sessionID)
}

struct LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            ActivityCardView(model: card(context))
                .widgetURL(sessionURL(context))
        } dynamicIsland: { context in
            let model = card(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CardOrb(model: model, size: 46)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandTitle(model: model)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        CardClock(model: model, font: .callout.weight(.semibold))
                        Text(model.server)
                            .font(.caption2)
                            .foregroundStyle(model.inks.dim)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 6)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(model: model)
                }
            } compactLeading: {
                IslandDot(model: model, size: 22)
            } compactTrailing: {
                IslandTrailing(model: model)
            } minimal: {
                IslandDot(model: model, size: 22)
            }
            .widgetURL(sessionURL(context))
            .keylineTint(model.ink)
            .contentMargins(.horizontal, 14, for: .expanded)
        }
        .supplementalActivityFamilies([.small])
    }
}
