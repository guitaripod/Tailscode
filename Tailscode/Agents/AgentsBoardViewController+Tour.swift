#if DEBUG
    import UIKit

    extension AgentsBoardViewController {
        var tourPeekScrollView: UIScrollView? { peek?.scrollView }

        func tourOpenPeek(titled title: String) {
            guard let row = board.working.first(where: { $0.title == title }) else { return }
            presentPeek(AgentsPeekTarget(row: row))
        }

        func tourDismissPeek() async {
            guard let peek else { return }
            await withCheckedContinuation { continuation in
                peek.dismiss(animated: true) { continuation.resume() }
            }
        }
    }
#endif
