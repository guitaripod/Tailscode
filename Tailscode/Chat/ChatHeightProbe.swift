#if DEBUG
    import Foundation
    import TailscodeCore
    import UIKit

    /// What a transcript costs in points, read after its rows have settled. A self-sizing list
    /// only knows the height of a row once that row has been laid out, so the page is walked end to
    /// end first and the size read when every row has been measured; `TAILSCODE_MEASURE_HEIGHT=1`
    /// turns it on, which is how the compact chat's before and after are compared.
    @MainActor
    final class ChatHeightProbe {
        private let sessionID: String
        private var settling: Task<Void, Never>?
        private var lastLogged: CGFloat = -1

        init(sessionID: String) {
            self.sessionID = sessionID
        }

        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["TAILSCODE_MEASURE_HEIGHT"] == "1"
        }

        /// Called whenever the list's content size moved; waits for it to stop moving, then
        /// measures once.
        func contentMoved(of collectionView: UICollectionView, rows: @escaping () -> Int) {
            guard Self.isEnabled else { return }
            settling?.cancel()
            settling = Task { [weak self, weak collectionView] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self, let collectionView, collectionView.window != nil
                else { return }
                self.measure(collectionView, rows: rows())
            }
        }

        private func measure(_ collectionView: UICollectionView, rows: Int) {
            let origin = collectionView.contentOffset
            let page = max(200, collectionView.bounds.height * 0.6)
            var y = -collectionView.adjustedContentInset.top
            while y < collectionView.contentSize.height {
                collectionView.contentOffset = CGPoint(x: 0, y: y)
                collectionView.layoutIfNeeded()
                y += page
            }
            collectionView.contentOffset = origin
            let height = collectionView.collectionViewLayout.collectionViewContentSize.height
            guard abs(height - lastLogged) > 0.5 else { return }
            lastLogged = height
            let everything = CGRect(x: 0, y: 0, width: collectionView.bounds.width, height: height)
            let heights = (collectionView.collectionViewLayout.layoutAttributesForElements(in: everything) ?? [])
                .sorted { $0.frame.minY < $1.frame.minY }
                .map { "\($0.indexPath.item):\(Int($0.frame.height.rounded()))" }
                .joined(separator: " ")
            AppLogger.performance.info("chat rowHeights \(heights) session=\(sessionID)")
            AppLogger.performance.info(
                "chat contentHeight=\(Int(height.rounded())) rows=\(rows) density=\(ChatDensitySetting.current.rawValue) session=\(sessionID)")
        }
    }
#endif
