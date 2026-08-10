import AppIntents
import SwiftUI
import WidgetKit

/// A question is not work, so its control carries no state to read: the tile is the gesture.
/// Control Center, the Lock Screen and the Action Button all reach the same composer the app's
/// own sparkle does, which is the point — a lookup should cost one press from wherever the phone
/// already is.
struct QuickAskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.guitaripod.tailscode.QuickAskControl") {
            ControlWidgetButton(action: QuickAskIntent()) {
                Label {
                    Text(LocalizedStringResource("Quick Ask"))
                } icon: {
                    Image(systemName: "sparkle")
                }
            }
        }
        .displayName(LocalizedStringResource("Quick Ask"))
        .description(LocalizedStringResource("Ask your agent anything, no project, no setup."))
    }
}
