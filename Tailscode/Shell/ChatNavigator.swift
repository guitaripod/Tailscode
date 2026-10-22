import TailscodeCore
import UIKit

/// The one door every chat goes through on its way onto a navigation stack.
///
/// A push begun while the stack is still animating a push or a pop is what leaves the interactive
/// pop recogniser waiting on a transition that never finishes the way it expected, so a road that
/// wants to open a chat asks here first. The answer comes from `ChatNavigationGuard` (Core) and the
/// two facts only UIKit knows: which chat is on top, and whether a transition is running. A request
/// that has to wait is held and retried from the transition's own completion, never from a run-loop
/// hop that spins until the animation is over.
@MainActor
final class ChatNavigator {
    static let shared = ChatNavigator()

    private var guardrail = ChatNavigationGuard()
    private var retry: (() -> Void)?
    private weak var holdingStack: UINavigationController?

    private init() {}

    /// Decides whether `target` may go onto `stack` now. When it may not because a transition is
    /// running, `retry` runs after that transition ends, unless a later request replaced it first.
    func admit(
        _ target: ChatTarget, on stack: UINavigationController, retry: @escaping () -> Void
    ) -> ChatNavigationGuard.Verdict {
        let verdict = guardrail.request(
            target, top: Self.target(of: stack.topViewController),
            transitioning: stack.transitionCoordinator != nil)
        AppLogger.session.info(
            "chat push \(verdict) session=\(target.sessionID) top=\(Self.target(of: stack.topViewController)?.sessionID ?? "-") transitioning=\(stack.transitionCoordinator != nil)")
        switch verdict {
        case .hold:
            self.retry = retry
            holdingStack = stack
            AppLogger.session.info(
                "chat push held behind a transition session=\(target.sessionID)")
            stack.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                self?.transitionEnded()
            }
        case .alreadyOnTop, .push:
            self.retry = nil
        }
        return verdict
    }

    func push(_ chat: ChatViewController, on stack: UINavigationController, animated: Bool) {
        let target = ChatTarget(contextID: chat.contextID, sessionID: chat.sessionID)
        switch admit(
            target, on: stack, retry: { [weak self, weak stack] in
                guard let stack else { return }
                self?.push(chat, on: stack, animated: animated)
            })
        {
        case .push:
            stack.pushViewController(chat, animated: animated)
        case .alreadyOnTop:
            Theme.Haptics.tap()
            (stack.topViewController as? ChatViewController)?.announceIdentity()
        case .hold:
            break
        }
    }

    private func transitionEnded() {
        guard let stack = holdingStack else {
            retry = nil
            return
        }
        let next = guardrail.settled(top: Self.target(of: stack.topViewController))
        let run = retry
        retry = nil
        holdingStack = nil
        guard next != nil else { return }
        run?()
    }

    private static func target(of controller: UIViewController?) -> ChatTarget? {
        (controller as? ChatViewController).map {
            ChatTarget(contextID: $0.contextID, sessionID: $0.sessionID)
        }
    }
}
