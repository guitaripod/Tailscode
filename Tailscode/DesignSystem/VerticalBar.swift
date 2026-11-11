import UIKit

/// Whether the system draws a screen's bars down a side edge rather than across its top and
/// bottom, which an iPhone Duo does on its outer display and on its inner display held sideways.
///
/// Read from the traits every time, never from the device: one window gains and loses the bar by
/// folding, turning or sharing the screen, and a split view's list column keeps horizontal bars
/// while the window around it has a vertical one. In that bar the navigation item's buttons stack
/// at the top and the view controller's toolbar items dock at the foot, under the thumb.
enum VerticalBar {
    static func isPresent(in traits: UITraitCollection?) -> Bool {
        #if canImport(UIKit, _version: 9127.0.85)
            guard #available(iOS 27.1, *), let traits else { return false }
            return traits.verticalBarEdge == .leading || traits.verticalBarEdge == .trailing
        #else
            return false
        #endif
    }

    /// Calls `changed` on `controller` whenever a trait that can move its bars changes.
    @MainActor
    static func observe<Controller: UIViewController>(
        _ controller: Controller, _ changed: @escaping @MainActor (Controller) -> Void
    ) {
        #if canImport(UIKit, _version: 9127.0.85)
            guard #available(iOS 27.1, *) else { return }
            controller.registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                (observed: Controller, _: UITraitCollection) in
                MainActor.assumeIsolated { changed(observed) }
            }
        #endif
    }

    /// Asks a bar item to stay in the bar ahead of its neighbours, or to be the first to leave for
    /// the overflow menu, when the bar runs short — on the outer display held sideways, or above
    /// the keyboard.
    @MainActor
    static func rank(_ item: UIBarButtonItem, _ rank: Rank) {
        #if canImport(UIKit, _version: 9127.0.85)
            guard #available(iOS 27.0, *) else { return }
            switch rank {
            case .keep: item.visibilityPriority = .high
            case .standard: item.visibilityPriority = .standard
            case .first: item.visibilityPriority = .low
            }
        #endif
    }

    enum Rank { case keep, standard, first }
}
