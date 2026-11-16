import SwiftUI
import TailscodeCore
import WidgetKit

@main
struct TailscodeWidgetBundle: WidgetBundle {
    init() {
        TailscodeLogging.configure()
        LiveActivitySettings.suiteName = UsageWidgetStore.suiteName
    }

    var body: some Widget {
        UsageWidget()
        TopUsageControl()
        QuickAskControl()
        AgentsControl()
        LiveActivityWidget()
    }
}
