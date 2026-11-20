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
    /// The side the action done most often belongs on while the screen is held sideways in both
    /// hands, or nil while it is held another way: the side of the window that meets the glass, so
    /// the thumb resting there reaches it — the leading side of a window sharing the screen from
    /// its left, the trailing side otherwise. A control that cannot reach that edge itself still
    /// sits at its nearer end.
    @MainActor
    static func primarySide(for view: UIView) -> Side? {
        let reach = read(for: view)
        return reach.isTwoThumbs ? reach.outerSide : nil
    }
}

extension UIView {
    /// The hold of the window this view is in.
    var handReach: HandReach { HandReach.read(for: self) }
}
