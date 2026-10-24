import SwiftUI
import WidgetKit

@main
struct TailscodeWidgetBundle: WidgetBundle {
    init() {
        TailscodeLogging.configure()
    }

    var body: some Widget {
        UsageWidget()
        TopUsageControl()
        QuickAskControl()
        LiveActivityWidget()
    }
}
