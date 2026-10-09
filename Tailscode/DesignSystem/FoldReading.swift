import UIKit

/// Where the fold of a folding iPhone lies in one view, read fresh on every layout pass.
///
/// The system reports a division region whether or not the device is folded; it is only active
/// while it is partly folded. A region that runs the whole height of the view is a vertical fold
/// (a book standing open, two pages side by side), and one that runs the whole width is a
/// horizontal fold (a laptop, a top region over a bottom one). Nothing here ever reads the hinge
/// angle: a layout comes from the regions the system hands over, never from a pose it guesses.
@MainActor
struct FoldReading: Equatable {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    let frame: CGRect
    let isActive: Bool

    var isBook: Bool { isActive && axis == .vertical }

    var isLaptop: Bool { isActive && axis == .horizontal }

    /// The fold in `view`'s coordinates, or nil on a device that has none or while the view is
    /// too small to be crossed by it. Inactive folds are included so a grid can choose its columns
    /// before the device is ever folded.
    static func read(in view: UIView) -> FoldReading? {
        #if canImport(UIKit, _version: 9127.0.85)
            guard #available(iOS 27.1, *), view.window != nil else { return nil }
            let regions = view.reservedRegions(kind: .division, options: [.includeInactive])
            guard let region = regions.max(by: { $0.isActive == false && $1.isActive }) else {
                return nil
            }
            let bounds = view.bounds
            let frame = region.frame
            let spansHeight = frame.height >= bounds.height - 1
            let spansWidth = frame.width >= bounds.width - 1
            switch (spansHeight, spansWidth) {
            case (true, false):
                return FoldReading(axis: .vertical, frame: frame, isActive: region.isActive)
            case (false, true):
                return FoldReading(axis: .horizontal, frame: frame, isActive: region.isActive)
            default:
                return nil
            }
        #else
            return nil
        #endif
    }

    /// Whether a grid in `view` should round its column count up to an even one, so no column
    /// straddles a vertical fold now or when the device is folded.
    static func prefersEvenColumns(in view: UIView) -> Bool {
        read(in: view)?.axis == .vertical
    }
}

extension UIViewController {
    /// Holds this screen to the page before a vertical fold by taking the other page, the fold and
    /// the system's own side inset out of its safe area, so everything pinned to the safe area
    /// stays on one page. A page narrower than a conversation is not worth holding to, and a
    /// fold that is not partly open holds nothing. Returns whether the screen is being held.
    @discardableResult
    func keepToPageBeforeFold(_ fold: FoldReading?) -> Bool {
        let narrowest: CGFloat = 280
        guard let fold, fold.isBook, fold.frame.minX >= narrowest,
            view.bounds.width - fold.frame.maxX >= narrowest
        else {
            if additionalSafeAreaInsets.right != 0 { additionalSafeAreaInsets.right = 0 }
            return false
        }
        let system = view.safeAreaInsets.right - additionalSafeAreaInsets.right
        let wanted = max(0, view.bounds.width - fold.frame.minX - system)
        if abs(additionalSafeAreaInsets.right - wanted) > 0.5 {
            additionalSafeAreaInsets.right = wanted
        }
        return true
    }
}
