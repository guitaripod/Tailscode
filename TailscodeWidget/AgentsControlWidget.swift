import AppIntents
import SwiftUI
import WidgetKit

/// The Agents board from Control Center, the Lock Screen or the Action Button: what every agent on
/// every machine is doing, one press from wherever the phone already is. Like the quick ask's, the
/// tile carries no state of its own to read; the board is the reading.
struct AgentsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.guitaripod.tailscode.AgentsControl") {
            ControlWidgetButton(action: OpenAgentsIntent()) {
                Label {
                    Text(LocalizedStringResource("Agents"))
                } icon: {
                    Image(systemName: "person.2")
                }
            }
        }
        .displayName(LocalizedStringResource("Agents"))
        .description(LocalizedStringResource("See what every agent is doing."))
    }
}
