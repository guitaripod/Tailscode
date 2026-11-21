import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// The figure each tile wears for its model: there for every tile that names one, a different
    /// shape for a different maker, moving only while the style lets it, and gone when switched off.
    static func checkWatchEmblems(_ check: WatchCheck, window: AgentsWindow, view: AgentsWatchView) throws {
        setWatchStyle(window, .studio)
        view.startScene("makers")
        check.pump(0.3)
        let tiles = view.wall.tiles
        let forms = Set(tiles.compactMap { $0.emblem?.form })
        try check.expect(tiles.count == 6 && forms.count >= 5, "six makers' models wear \(forms.count) different shapes")
        func pieces(_ tile: WallTile) -> [WallEmblemPiece] {
            view.tileView(tile.id)?.emblemPieces(width: 600, height: 300) ?? []
        }
        try check.expect(
            tiles.allSatisfy { !pieces($0).isEmpty && view.tileView($0.id)?.emblemMoves == true },
            "every running tile draws its figure and lets it move")
        var held = WallStyle.studio
        held.effects = .off
        setWatchStyle(window, held)
        check.pump(0.2)
        try check.expect(
            tiles.allSatisfy { !pieces($0).isEmpty && view.tileView($0.id)?.emblemMoves == false },
            "with effects off the figure is a drawing that does not move")
        held = .studio
        held.showsEmblems = false
        setWatchStyle(window, held)
        check.pump(0.2)
        try check.expect(
            tiles.allSatisfy { pieces($0).isEmpty && view.tileView($0.id)?.emblemMoves == false },
            "and the switch takes it off")
        setWatchStyle(window, .studio)
    }
}
