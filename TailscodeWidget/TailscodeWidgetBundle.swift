import SwiftUI
import WidgetKit

@main
struct TailscodeWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        LiveActivityWidget()
    }
}
