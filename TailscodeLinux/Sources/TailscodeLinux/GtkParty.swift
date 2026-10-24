import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension Gtk {
    /// Makes a party card something the pointer can pick up. `lift` is told when the card leaves the
    /// pointer's hand and when it is let go, so the card wears its lifted look exactly while it is
    /// in the air.
    static func makePartyDragSource(
        _ widget: UnsafeMutablePointer<GtkWidget>, payload: String,
        lift: @escaping @Sendable (Bool) -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(LiftBox(lift)).toOpaque()
        let callback: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { lifted, raw in
            guard let raw else { return }
            Unmanaged<LiftBox>.fromOpaque(raw).takeUnretainedValue().lift(lifted != 0)
        }
        tailscode_make_party_drag_source(widget, payload, callback, box)
    }

    /// A dragged party card over `widget`, reported exactly as a dragged chat is.
    static func acceptPartyDrops(
        on widget: UnsafeMutablePointer<GtkWidget>,
        motion: @escaping @Sendable (String?, Double, Double) -> Void,
        leave: @escaping @Sendable () -> Void,
        drop: @escaping @Sendable (String, Double, Double) -> Bool
    ) {
        attachDrops(tailscode_accept_party_drops, to: widget, motion: motion, leave: leave, drop: drop)
    }

    final class LiftBox: @unchecked Sendable {
        let lift: @Sendable (Bool) -> Void
        init(_ lift: @escaping @Sendable (Bool) -> Void) { self.lift = lift }
    }
}
