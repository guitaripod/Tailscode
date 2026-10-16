import CGtkShim
import Foundation
import TailscodeCore

/// Every road to what a machine can make arrives at one place: the shared checklist for images and
/// video, led by whichever of the two the person came for. The checklist names the machine it is
/// looking at and offers to change it, and changing it is the renderer picker that already exists,
/// which hands the person back to the checklist for the machine they chose.
///
/// A renderer that was never named has nothing to check yet, so the picker comes first and the
/// checklist follows it.
enum MediaChecklistFlow {
    static func open(
        endpoint: ForgeEndpoint?, focus: SetupFocus?, parent: UnsafeMutablePointer<GtkWidget>?,
        onFinish: (@Sendable () -> Void)? = nil, onChanged: @escaping @Sendable () -> Void = {}
    ) {
        guard let endpoint else {
            choose(focus: focus, parent: parent, onFinish: onFinish, onChanged: onChanged)
            return
        }
        nonisolated(unsafe) let host = parent
        SetupWindow.present(
            target: .media(endpoint), parent: parent, focus: focus, onFinish: onFinish,
            onChange: {
                Gtk.onMain { choose(focus: focus, parent: host, onFinish: onFinish, onChanged: onChanged) }
            })
    }

    private static func choose(
        focus: SetupFocus?, parent: UnsafeMutablePointer<GtkWidget>?, onFinish: (@Sendable () -> Void)?,
        onChanged: @escaping @Sendable () -> Void
    ) {
        nonisolated(unsafe) let host = parent
        ForgeSetupWindow.present(parent: parent) {
            Gtk.onMain {
                ForgeRunner.shared.pointAtStoredRenderer()
                onChanged()
                guard let next = ForgeStore.endpoint() else { return }
                open(endpoint: next, focus: focus, parent: host, onFinish: onFinish, onChanged: onChanged)
            }
        }
    }
}
