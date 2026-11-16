import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The picture that flies while the viewer's sheet arrives in place or leaves it: out of the tile
/// it was pressed in, and home to the tile of the page being shown (`PictureFlight`).
///
/// It is one paint widget over the whole window. On every frame of the sheet's own clock it draws
/// the tile's texture, clipped to the frame Core gives it and filling that frame, so no widget is
/// resized while it travels. The tile it left is not drawn while its picture is out, and the page
/// under it is not drawn while it flies; the last frame out and the page's first are the same
/// rectangle, because both come from `PictureFlight.stage` in the same room.
///
/// A viewer the Studio opened has no tiles and rises with the Studio's sheet as it always has.
final class ViewerFlight: @unchecked Sendable {
    /// A page's picture as the flight draws it: its texture, kept alive while it is in the air,
    /// and its shape.
    struct Picture {
        let key: String
        let bits: UInt
        let aspect: Double
    }

    /// The corners a strip tile is drawn with.
    static let tileRadius: Double = 6
    /// How much of a tile has to show through its transcript for a picture to fly to it.
    static let homeInSight = 0.5

    private let layer: SheetLayer
    private let paint = WallLayer()
    private var tiles: PictureTiles?
    private var flying: (picture: Picture, origin: PictureFlight.Rect, opening: Bool)?
    private var outKey: String?
    private var drew = false

    /// The room a page fits its picture into, in the window's own coordinates.
    var room: () -> PictureFlight.Rect? = { nil }
    /// How present the viewer's words and buttons are, 0…1.
    var setWords: (Double) -> Void = { _ in }
    /// Whether the page under the flight is drawn.
    var setPage: (Bool) -> Void = { _ in }

    init(layer: SheetLayer, tiles: PictureTiles?) {
        self.layer = layer
        self.tiles = tiles
        layer.float(paint.widget)
        paint.draw = { [weak self] snapshot, _, _ in self?.draw(snapshot) }
        layer.onPresence = { [weak self] time, opening in self?.moved(time, opening) }
        layer.onArrived = { [weak self] in self?.land() }
    }

    /// The viewer was pointed at other pictures: they stand in these tiles now.
    func retarget(tiles next: PictureTiles?, showing key: String) {
        takeOut(nil)
        tiles = next
        takeOut(key)
    }

    /// Chooses how the sheet comes: with `picture` flown out of its tile when that tile is in
    /// sight and motion is allowed, fading in place when it is not, and rising for a viewer that
    /// has no tiles at all.
    func arrive(with picture: Picture?) {
        guard tiles != nil else {
            layer.arrival = .rise
            return
        }
        layer.arrival = .inPlace
        guard let picture, let origin = home(of: picture) else {
            layer.inPlaceSpans.arriving = PictureFlight.fadeDuration
            takeOut(picture?.key)
            return
        }
        layer.inPlaceSpans.arriving = PictureFlight.openDuration
        start(picture, origin: origin, opening: true)
    }

    /// Chooses how the sheet goes: with the page's picture flown home when its tile is in sight,
    /// fading where it stands when it has none.
    func leave(with picture: Picture?) {
        guard tiles != nil else { return }
        layer.arrival = .inPlace
        guard let picture, let origin = home(of: picture) else {
            layer.inPlaceSpans.leaving = PictureFlight.fadeDuration
            return
        }
        layer.inPlaceSpans.leaving = PictureFlight.closeDuration
        start(picture, origin: origin, opening: false)
    }

    /// The viewer turned to another page: that page's tile is the one out of the chat now.
    func turned(to key: String) {
        guard tiles != nil else { return }
        land()
        takeOut(key)
    }

    /// The sheet has gone: the tile is drawn again and the layer is the Studio's to use.
    func finish() {
        land()
        takeOut(nil)
        layer.onPresence = nil
        layer.onArrived = nil
        layer.arrival = .rise
        layer.unfloat(paint.widget)
    }

    var isFlying: Bool { flying != nil }

    /// Where a picture's pixels are in the window right now, when its tile shows and motion is
    /// allowed: a cropped tile whole, a fitted one by the picture inside it.
    private func home(of picture: Picture) -> PictureFlight.Rect? {
        guard RepeatingMotion.allowed, picture.bits != 0, picture.aspect > 0,
            let tile = tiles?.tile(for: picture.key),
            let bounds = layer.bounds(of: tile.widget, inSight: Self.homeInSight)
        else { return nil }
        return PictureFlight.origin(tile: bounds, aspect: picture.aspect, fitted: tile.fitted)
    }

    private func start(_ picture: Picture, origin: PictureFlight.Rect, opening: Bool) {
        land()
        if let texture = UnsafeMutableRawPointer(bitPattern: picture.bits) { g_object_ref(texture) }
        flying = (picture, origin, opening)
        drew = false
        setPage(false)
        setWords(opening ? 0 : 1)
        if !opening { takeOut(picture.key) }
        paint.redraw()
    }

    /// The flight is over: the page is drawn again and the texture is let go.
    private func land() {
        guard let flown = flying else { return }
        flying = nil
        if let texture = UnsafeMutableRawPointer(bitPattern: flown.picture.bits) {
            g_object_unref(texture)
        }
        setPage(true)
        setWords(1)
        paint.redraw()
    }

    private func moved(_ time: Double, _ opening: Bool) {
        guard flying != nil else { return }
        setWords(PictureFlight.chrome(time: time, opening: opening))
        paint.redraw()
    }

    /// One tile is out of the chat at a time: the one whose picture the viewer is showing.
    private func takeOut(_ key: String?) {
        guard outKey != key else { return }
        if let outKey { tiles?.setOut(outKey, false) }
        outKey = key
        if let key { tiles?.setOut(key, true) }
    }

    private func draw(_ snapshot: WallSnapshot) {
        guard let flying, let room = room(),
            let texture = OpaquePointer(bitPattern: Int(bitPattern: flying.picture.bits))
        else { return }
        let stage = PictureFlight.stage(aspect: flying.picture.aspect, in: room)
        let moment = PictureFlight.moment(
            time: layer.progress, opening: flying.opening, origin: flying.origin, stage: stage,
            tileRadius: Self.tileRadius)
        let frame = moment.frame
        guard frame.isDrawable else { return }
        let whole = PictureFlight.fill(aspect: flying.picture.aspect, frame: frame)
        tailscode_snap_push_rounded_clip(
            snapshot.raw, frame.x, frame.y, frame.width, frame.height, moment.cornerRadius)
        tailscode_snap_texture(snapshot.raw, texture, whole.x, whole.y, whole.width, whole.height)
        gtk_snapshot_pop(snapshot.raw)
        hideTileOnceDrawn(flying.picture.key)
    }

    /// The tile leaves the chat only after the first frame of its picture in the air has been
    /// drawn over it, so there is never a frame with neither.
    private func hideTileOnceDrawn(_ key: String) {
        guard !drew else { return }
        drew = true
        Gtk.onMain { [weak self] in
            guard let self, self.flying?.picture.key == key else { return }
            self.takeOut(key)
        }
    }

    /// The flight as a check reads it: where the picture is drawn at this instant, where it left
    /// from and where the page fits it, or nil with nothing in the air.
    var reading: (frame: PictureFlight.Rect, origin: PictureFlight.Rect, stage: PictureFlight.Rect, opening: Bool)? {
        guard let flying, let room = room() else { return nil }
        let stage = PictureFlight.stage(aspect: flying.picture.aspect, in: room)
        let frame = PictureFlight.moment(
            time: layer.progress, opening: flying.opening, origin: flying.origin, stage: stage,
            tileRadius: Self.tileRadius
        ).frame
        return (frame, flying.origin, stage, flying.opening)
    }

    /// What a harness reads: whether a picture is in the air and where it was drawn last.
    var summary: String {
        guard let flying, let room = room() else { return "flight=none out=\(outKey ?? "-")" }
        let stage = PictureFlight.stage(aspect: flying.picture.aspect, in: room)
        let frame = PictureFlight.moment(
            time: layer.progress, opening: flying.opening, origin: flying.origin, stage: stage,
            tileRadius: Self.tileRadius
        ).frame
        return
            "flight=\(flying.opening ? "out" : "home") key=\(flying.picture.key) frame=\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)) origin=\(Int(flying.origin.x)),\(Int(flying.origin.y)) \(Int(flying.origin.width))x\(Int(flying.origin.height)) stage=\(Int(stage.x)),\(Int(stage.y)) \(Int(stage.width))x\(Int(stage.height)) out=\(outKey ?? "-")"
    }
}
