import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MatrixStylesheet {
    /// What a theme with scenery adds to the sheet, written last so these are the rules in force.
    /// A palette with none adds nothing, and the sheet is the one it always was.
    ///
    /// The sky is the background of the canvas the panes stand on (`tile-canvas.pane-canvas`, and
    /// only that one: the Agents board lays its tiles out on canvases of the same kind), behind
    /// every pane at once, so a split is one sky seen through several windows rather than the
    /// same stars repeated in each. The panes and their transcripts go clear to let it through;
    /// everything a person reads off a raised surface (the chat list, the box, the band, a card,
    /// a code block) keeps its own ground.
    func sceneryRules() -> String {
        guard let scenery = palette.scenery else { return "" }
        return [
            skyRules(scenery.sky),
            bladeRules(glow: scenery.bladeGlow),
            horizonRules(),
            projectionRules(share: scenery.scanLines),
            shadowRules(share: scenery.castShadow),
        ].joined(separator: "\n")
    }

    private func skyRules(_ sky: Scenery.Sky) -> String {
        let layers: [SceneryCSS.Layer]
        var horizon = ""
        switch sky {
        case .stars(let field):
            layers = SceneryCSS.stars(field) + field.washes.map(SceneryCSS.wash)
        case .suns(let suns):
            layers = suns.dunes.reversed().map(SceneryCSS.dune) + suns.washes.map(SceneryCSS.wash)
            let discs = suns.suns.map(SceneryCSS.sun)
            horizon = """
                headerbar.content-header {
                    background-image: \(discs.map(\.image).joined(separator: ", "));
                    background-repeat: \(discs.map(\.repeats).joined(separator: ", "));
                }
                """
        }
        return """
        tile-canvas.pane-canvas {
            background-color: \(canvas);
            background-image: \(layers.map(\.image).joined(separator: ", "));
            background-repeat: \(layers.map(\.repeats).joined(separator: ", "));
        }
        .tile-shell, .chat-pane.canvas, .chat-pane .transcript { background-color: transparent; }
        \(horizon)
        """
    }

    /// A signal drawn as a bar, lit: a core lifted toward white inside its own colour's light.
    /// The light stays inside the gap between the bar and the words beside it, because a glow
    /// under type is a smear. With no glow the bars stay ink and only the box's edge is drawn,
    /// which it is in either face: the edge of the box being typed in strikes across from the
    /// leading side when the keyboard arrives and withdraws when it leaves.
    private func bladeRules(glow: Double) -> String {
        let lit = glow > 0
        let core = lit ? SceneryCSS.core(of: accent) : accent
        let failedCore = lit ? SceneryCSS.core(of: danger) : danger
        let near = SceneryCSS.points(glow * 0.6)
        let far = SceneryCSS.points(glow * 1.2)
        func spill(_ hex: String) -> String {
            lit ? "box-shadow: 0 0 \(near) alpha(\(hex), 0.95), 0 0 \(far) alpha(\(hex), 0.45);" : ""
        }
        let chosen =
            lit
            ? "box-shadow: inset 2px 0 0 \(core), inset 9px 0 12px -7px alpha(\(accent), 0.7);"
            : ""
        let halo = lit ? "box-shadow: 0 -5px 14px -6px alpha(\(accent), 0.6);" : ""
        let haloVisual = lit ? "box-shadow: 0 -5px 14px -6px alpha(\(info), 0.6);" : ""
        return """
        .prompt-rule { background-color: \(core); border-radius: 1px; \(spill(accent)) }
        .prompt-rule.queued-rule { box-shadow: none; }
        .prompt-rule.pending-rule-failed { background-color: \(failedCore); \(spill(danger)) }
        .row-focused, .row-focused:hover, .row-focused:active { \(chosen) }
        .composer {
            background-image: linear-gradient(to right, \(core), \(accent));
            background-repeat: no-repeat;
            background-position: left top;
            background-size: 0% 2px;
            transition: background-size 420ms cubic-bezier(0.2, 0.9, 0.2, 1),
                box-shadow 420ms ease-out;
        }
        .composer:focus-within { background-size: 100% 2px; \(halo) }
        .composer.composer-visual {
            background-image: linear-gradient(to right, \(lit ? SceneryCSS.core(of: info) : info), \(info));
        }
        .composer.composer-visual:focus-within { \(haloVisual) }
        """
    }

    /// A hairline that crosses the canvas fades out toward both ends, so a turn ends on a horizon
    /// rather than on a ruled line, and the sky is not boxed in by it.
    private func horizonRules() -> String {
        return """
        .chat-pane .turn-rule {
            background-color: transparent;
            background-image: linear-gradient(
                to right, alpha(\(rule), 0), \(rule) 12%, \(rule) 88%, alpha(\(rule), 0));
        }
        """
    }

    /// What the agent delegated is work happening somewhere else, shown here: its card is scanned
    /// in the colour its own edge already wears, with the light of the projector in the corner
    /// the edge starts from.
    private func projectionRules(share: Double) -> String {
        guard share > 0 else { return "" }
        func projected(_ hex: String) -> String {
            let line = SceneryCSS.share(share)
            let lamp = SceneryCSS.share(share * 2.2)
            return """
            background-image:
                    repeating-linear-gradient(
                        to bottom, alpha(\(hex), \(line)) 0px, alpha(\(hex), \(line)) 1px,
                        alpha(\(hex), 0) 1px, alpha(\(hex), 0) 3px),
                    radial-gradient(
                        ellipse farthest-corner at 0% 0%, alpha(\(hex), \(lamp)), alpha(\(hex), 0) 62%);
            """
        }
        return """
        .subagent-card { \(projected(info)) }
        .workflow-card { \(projected(accent)) }
        """
    }

    /// Under a high sun the chrome casts a short shadow with no blur onto the canvas beside it.
    private func shadowRules(share: Double) -> String {
        guard share > 0 else { return "" }
        return """
        tile-canvas.pane-canvas {
            box-shadow: inset 3px 0 0 alpha(\(text), \(SceneryCSS.share(share))),
                inset 0 3px 0 alpha(\(text), \(SceneryCSS.share(share * 0.7)));
        }
        """
    }
}

/// Core's scenery as the stylesheet's own words: a star layer is a picture painted once and named
/// by a `data:` address, a wash and a sun are gradients. Nothing here is a file on disk.
enum SceneryCSS {
    struct Layer {
        let image: String
        let repeats: String
    }

    static func stars(_ field: StarField) -> [Layer] {
        field.layers.compactMap { layer in
            guard let address = SceneryPictures.address(of: layer, in: field) else { return nil }
            return Layer(image: "url(\"\(address)\")", repeats: "repeat")
        }
    }

    static func wash(_ wash: SkyWash) -> Layer {
        Layer(
            image: """
                radial-gradient(ellipse farthest-corner at \(percent(wash.x)) \(percent(wash.y)), \
                alpha(\(wash.color), \(share(wash.alpha))), \
                alpha(\(wash.color), 0) \(percent(wash.reach)))
                """,
            repeats: "no-repeat")
    }

    /// A dune is the upper arc of a wide ellipse resting on the canvas's lower edge: one flat
    /// tint up to a crest that takes a line of light, then nothing.
    static func dune(_ dune: TwinSuns.Dune) -> Layer {
        Layer(
            image: """
                radial-gradient(ellipse \(percent(dune.reach)) \(points(dune.height)) at \
                \(percent(dune.x)) 100%, \
                alpha(\(dune.color), \(share(dune.alpha))) 0%, \
                alpha(\(dune.color), \(share(dune.alpha))) 98.7%, \
                alpha(\(dune.crest), 0.55) 99.2%, \
                alpha(\(dune.crest), 0.55) 99.6%, \
                alpha(\(dune.crest), 0) 100%)
                """,
            repeats: "no-repeat")
    }

    /// A sun is a disc with a soft rim inside a corona that is gone by a little over three radii,
    /// placed from the bar's lower edge, which is the horizon it stands on.
    static func sun(_ sun: TwinSuns.Sun) -> Layer {
        let reach = sun.radius * 3.4
        let rim = sun.radius / reach
        return Layer(
            image: """
                radial-gradient(circle \(points(reach)) at \(points(sun.x)) \
                calc(100% - \(points(sun.rise))), \
                alpha(\(sun.core), \(share(sun.alpha))) 0%, \
                alpha(\(sun.core), \(share(sun.alpha))) \(percent(rim * 0.9)), \
                alpha(\(sun.corona), \(share(sun.alpha * 0.72))) \(percent(rim * 1.08)), \
                alpha(\(sun.corona), \(share(sun.alpha * 0.26))) \(percent(rim * 1.8)), \
                alpha(\(sun.corona), 0) 100%)
                """,
            repeats: "no-repeat")
    }

    /// A blade's core: its own colour most of the way to white, which is what a lit bar looks
    /// like at the centre of its own light.
    static func core(of hex: String) -> String {
        Contrast.blend(hex, "#ffffff", 0.55) ?? hex
    }

    static func percent(_ unit: Double) -> String { String(format: "%.2f%%", unit * 100) }

    static func points(_ value: Double) -> String { String(format: "%.1fpx", value) }

    static func share(_ value: Double) -> String { String(format: "%.3f", value) }
}

/// The pictures a sky is tiled from, painted once per process: a layer's stars never change, so
/// neither does its picture, and a type-size change that rewrites the sheet finds it made.
enum SceneryPictures {
    private nonisolated(unsafe) static var made: [String: String] = [:]
    private static let lock = NSLock()

    static func address(of layer: StarField.Layer, in field: StarField) -> String? {
        let key = "\(layer.tile)/\(layer.seed)/\(layer.count)/\(layer.radius)/\(layer.alpha)/"
            + "\(layer.halo)/\(field.tints.joined(separator: ","))"
        lock.lock()
        defer { lock.unlock() }
        if let address = made[key] { return address }
        let picture = field.bitmap(layer)
        guard let text = tailscode_rgba_data_url(picture.rgba, Int32(picture.side), Int32(picture.side))
        else { return nil }
        let address = String(cString: text)
        g_free(text)
        made[key] = address
        return address
    }
}
