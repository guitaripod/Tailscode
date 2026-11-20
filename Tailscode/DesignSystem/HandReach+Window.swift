import TailscodeCore
import UIKit

extension HandReach {
    /// Posted when the window may have moved on its screen without changing size: tiled to the
    /// other side, dragged in Stage Manager, or the device turned.
    static let didChange = Notification.Name("tailscode.handReach.didChange")

    /// The hold for the window `view` is in, read from where that window lies on its screen.
    @MainActor
    static func read(for view: UIView) -> HandReach {
        guard let window = view.window, let scene = window.windowScene else { return .ordinary }
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        #if DEBUG
            if let staged = staged(window: window, rightToLeft: rightToLeft) { return staged }
        #endif
        let space = scene.screen.coordinateSpace
        let frame = window.convert(window.bounds, to: space)
        return read(
            windowX: Double(frame.minX), windowWidth: Double(frame.width),
            screenWidth: Double(space.bounds.width), screenHeight: Double(space.bounds.height),
            rightToLeft: rightToLeft)
    }

    #if DEBUG
        /// A window turned a quarter by `TAILSCODE_WINDOW` stands for a screen held sideways, and
        /// `TAILSCODE_REACH=leading|trailing` puts it against one edge of a wider one, so every hold
        /// is photographed on a simulator that boots upright.
        @MainActor
        private static func staged(window: UIWindow, rightToLeft: Bool) -> HandReach? {
            let env = ProcessInfo.processInfo.environment
            let side = env["TAILSCODE_REACH"]
            guard !window.transform.isIdentity || side != nil else { return nil }
            let width = Double(window.bounds.width)
            let screen = max(width * 1.43, Double(window.bounds.height) * 1.43, 1194)
            let height = screen / 1.43
            let x: Double
            switch side {
            case "leading": x = rightToLeft ? screen - width : 0
            case "trailing": x = rightToLeft ? 0 : screen - width
            default: return read(
                windowX: 0, windowWidth: width, screenWidth: width,
                screenHeight: Double(window.bounds.height), rightToLeft: rightToLeft)
            }
            return read(
                windowX: x, windowWidth: width, screenWidth: screen, screenHeight: height,
                rightToLeft: rightToLeft)
        }
    #endif
}

extension HandReach {
    /// The side of `view` the action done most often belongs on while the screen is held in both
    /// hands, or nil while it is held the ordinary way: the window's outer side when `view` begins
    /// within `slack` of the window's edge on that side, so the thumb on that edge reaches it, and
    /// the trailing side otherwise.
    @MainActor
    static func primarySide(for view: UIView, within slack: CGFloat) -> Side? {
        let reach = read(for: view)
        guard reach.isTwoThumbs else { return nil }
        guard reach.outerSide == .leading, let window = view.window else { return .trailing }
        let frame = view.convert(view.bounds, to: window)
        let gap =
            view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? window.bounds.width - frame.maxX + view.safeAreaInsets.right
            : frame.minX + view.safeAreaInsets.left
        return gap <= slack ? .leading : .trailing
    }
}

extension UIView {
    /// The hold of the window this view is in.
    var handReach: HandReach { HandReach.read(for: self) }
}
