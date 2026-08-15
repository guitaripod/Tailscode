import SwiftUI
import WidgetKit

/// Everything this Mac publishes outside its own window: the Usage widget for Notification Centre
/// and the desktop, and the Control Centre button that carries the tightest window on its face.
@main
struct TailscodeMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacUsageWidget()
        TopUsageControl()
    }
}
