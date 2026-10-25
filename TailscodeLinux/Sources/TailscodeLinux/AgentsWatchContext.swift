import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What every part of the wall shares: the palette it is drawn in, the clock it waits by, the unit
/// its sizes are multiples of, and the doors out of it (a peek, a chat, an answer).
final class WatchContext: @unchecked Sendable {
    var palette = WatchPalette.current()
    let clock = WatchClock()
    var unit = 10.8
    var animated = RepeatingMotion.allowed
    var allowsBigType = true
    let actions: AgentsActions
    var openPeek: (String) -> Void = { _ in }
    var touched: () -> Void = {}
    var plainModel: PlainWordsModel?

    init(actions: AgentsActions) {
        self.actions = actions
    }

    var seconds: Double { clock.seconds }

    func size(_ units: Double) -> Double { max(max(WatchGeometry.minimumText * unit, 9), units * unit) }

    func label(
        _ units: Double, bold: Bool = false, mono: Bool = false, ink: PartyInk? = nil, alpha: Double = 1
    ) -> WatchLabel.Style {
        WatchLabel.Style(size: size(units), bold: bold, mono: mono, ink: ink ?? palette.text, alpha: alpha)
    }
}
