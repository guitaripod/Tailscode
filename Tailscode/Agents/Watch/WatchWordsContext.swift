import TailscodeCore
import UIKit

/// What a tile's buttons are doing, kept by the wall per ask and shown on the tile.
enum WatchAction: Equatable {
    enum Kind: Equatable { case approve, deny }

    case hint
    case busy(Kind)
    case done(Kind)
    case failed(String)

    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }
}

/// Everything the words of one reading are set from, so a view changes only when this does.
struct WatchWordsContext {
    var wall: AgentWall
    var layout: WallLayout
    var palette: WallPalette
    var style: WallStyle
    var scale: WatchScale
    var now: Date
    var batteryHeld: Bool
    var actions: [String: WatchAction]
}

extension AgentWall {
    var hasFailure: Bool {
        tiles.contains { tile in
            if case .finished(.failed) = tile.state { return true }
            return false
        }
    }
}
