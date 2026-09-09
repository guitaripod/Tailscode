import Foundation

/// Where this device sends words it wants painted, and what it last saw there.
///
/// One ComfyUI holds the picture models and the video models alike, so the address is not a
/// second thing to go and find: a machine filed for rendering is a machine that can make a
/// picture, through the same door. What is kept here is only what the forge's own store keeps —
/// an address, the shape of the last ask — because there is no account, no key and no project in
/// any of it.
public enum ImageGenStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let endpointKey = "tailscode.image.endpoint"
    static let engineKey = "tailscode.image.engine"
    static let aspectKey = "tailscode.image.aspect"
    static let healthKey = "tailscode.image.health"
    public static let didChange = Notification.Name("tailscode.image.didChange")

    /// The address this device was told to make pictures on, which is not the same question as
    /// the one ``ImageGenDoor`` answers: a machine inherited from the video renderer is never
    /// filed here, so pointing the renderer somewhere else moves the pictures with it.
    public static func filedEndpoint() -> ImageGenEndpoint? {
        guard let data = defaults.data(forKey: endpointKey) else { return nil }
        return try? JSONDecoder().decode(ImageGenEndpoint.self, from: data)
    }

    public static func remember(_ endpoint: ImageGenEndpoint?) {
        guard let endpoint else {
            defaults.removeObject(forKey: endpointKey)
            NotificationCenter.default.post(name: didChange, object: nil)
            return
        }
        guard let data = try? JSONEncoder().encode(endpoint) else { return }
        defaults.set(data, forKey: endpointKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func engine() -> ImageGenEngine {
        defaults.string(forKey: engineKey).flatMap(ImageGenEngine.init(rawValue:)) ?? .quality
    }

    public static func aspect() -> ImageGenAspect {
        defaults.string(forKey: aspectKey).flatMap(ImageGenAspect.init(rawValue:)) ?? .square
    }

    public static func remember(engine: ImageGenEngine, aspect: ImageGenAspect) {
        defaults.set(engine.rawValue, forKey: engineKey)
        defaults.set(aspect.rawValue, forKey: aspectKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// What the machine last answered, kept so a surface drawn before any probe returns says the
    /// last true thing rather than a guess. A stamp nobody has written is not "offline".
    public static func lastSeen() -> ImageGenSighting? {
        guard let data = defaults.data(forKey: healthKey) else { return nil }
        return try? JSONDecoder().decode(ImageGenSighting.self, from: data)
    }

    public static func record(_ sighting: ImageGenSighting) {
        guard let data = try? JSONEncoder().encode(sighting) else { return }
        defaults.set(data, forKey: healthKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func forget() {
        for key in [endpointKey, engineKey, aspectKey, healthKey] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// One look at the drawing machine: where it was, whether it answered, and when the looking
/// happened. Stored rather than recomputed because the answer outlives the surface that asked.
public struct ImageGenSighting: Sendable, Equatable, Codable {
    public let host: String
    public let reachable: Bool
    public let missingModels: [String]
    public let at: Date

    public init(host: String, reachable: Bool, missingModels: [String] = [], at: Date = Date()) {
        self.host = host
        self.reachable = reachable
        self.missingModels = missingModels
        self.at = at
    }

    public init(endpoint: ImageGenEndpoint, health: ImageGenHealth, at: Date = Date()) {
        self.init(
            host: endpoint.displayHost, reachable: health.reachable,
            missingModels: health.missingModels, at: at)
    }

    public var ready: Bool { reachable && missingModels.isEmpty }
}

/// Whether this device has anywhere to send a picture, and what the lane that offers it should
/// say once it is there.
///
/// The rule is the one the renderer's setup already argues for and is the whole of what "no
/// switch" means here: a machine is known or it is not. ComfyUI is socket-activated and stops
/// itself when idle, so silence from a machine that has been filed is a machine asleep rather
/// than a machine gone — a lane that vanished every time the box dozed would be a lane nobody
/// could learn. So the door opens on an address existing, and the health decides what the lane
/// says rather than whether it is there.
public struct ImageGenDoor: Sendable, Equatable {
    public let endpoint: ImageGenEndpoint?
    public let inherited: Bool
    public let sighting: ImageGenSighting?

    public init(
        endpoint: ImageGenEndpoint?, inherited: Bool = false, sighting: ImageGenSighting? = nil
    ) {
        self.endpoint = endpoint
        self.inherited = inherited
        self.sighting = sighting
    }

    /// The address in force, preferring one filed for pictures over the video renderer's machine.
    /// Nothing is invented: a device that has pointed at neither has no door, and the lane that
    /// would open it is not offered.
    public static func resolve(
        filed: ImageGenEndpoint?, forge: ForgeEndpoint?, sighting: ImageGenSighting? = nil
    ) -> ImageGenDoor {
        if let filed {
            return ImageGenDoor(endpoint: filed, inherited: false, sighting: sighting)
        }
        if let forge {
            return ImageGenDoor(
                endpoint: ImageGenEndpoint(sharing: forge), inherited: true, sighting: sighting)
        }
        return ImageGenDoor(endpoint: nil, inherited: false, sighting: sighting)
    }

    /// What every client reads at launch and on every change either store posts.
    public static func current() -> ImageGenDoor {
        resolve(
            filed: ImageGenStore.filedEndpoint(), forge: ForgeStore.endpoint(),
            sighting: ImageGenStore.lastSeen())
    }

    public var isOpen: Bool { endpoint != nil }

    /// The machine's own name for a chip, never the address it was reached at.
    public var machine: String? { endpoint?.shortName }

    /// A sighting that is about the machine in force. An answer filed against an address nobody
    /// draws on any more says nothing about this one.
    public var currentSighting: ImageGenSighting? {
        guard let endpoint, let sighting, sighting.host == endpoint.displayHost else { return nil }
        return sighting
    }

    /// What the lane's own line says under the box. A machine nobody has looked at yet is not
    /// described, because a guess dressed as a fact is the one thing this vocabulary refuses.
    public var line: String? {
        guard let endpoint else { return nil }
        guard let sighting = currentSighting else {
            return inherited
                ? Localized.text("Renders on %@, the machine that makes video", endpoint.shortName)
                : nil
        }
        if sighting.ready { return nil }
        if !sighting.reachable {
            return Localized.text("%@ was not answering when this was last checked", endpoint.shortName)
        }
        return Localized.text(
            "%@ is answering, but %@ model files are missing", endpoint.shortName,
            "\(sighting.missingModels.count)")
    }

    /// The mark the lane wears. Nothing while a machine is well, and never a decoration on one
    /// nobody has looked at.
    public var tone: ActivityTone? {
        guard let sighting = currentSighting else { return nil }
        if sighting.ready { return nil }
        return sighting.reachable ? .attention : .quiet
    }
}

/// The image door's rules, checked headlessly — where a picture is sent when nobody has said,
/// which lanes a composer grows because of it, and the one rule that keeps a sleeping machine
/// from taking the lane away with it. Run from both desktops' `--selftest`.
public enum ImageGenDoorCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        let arch = ForgeEndpoint(host: "arch.taila1a09.ts.net")
        expect(
            ImageGenDoor.resolve(filed: nil, forge: nil).endpoint == nil,
            "a device that has pointed at nothing has no door")
        expect(
            QuickAskLane.offered(imaging: false) == [.chat, .ask, .video],
            "and its composer grows no image lane")
        expect(
            QuickAskLane.offered(imaging: true) == [.chat, .ask, .image, .video],
            "a machine that can paint puts the lane before the one that spends minutes")
        expect(
            QuickAskLane.chat.advanced(by: 1, among: QuickAskLane.offered(imaging: false)) == .ask,
            "a walk visits only the lanes the switch is showing")
        expect(
            QuickAskLane.video.advanced(by: 1, among: QuickAskLane.offered(imaging: false)) == .chat,
            "and wraps within them")

        let inherited = ImageGenDoor.resolve(filed: nil, forge: arch)
        expect(inherited.isOpen, "a renderer this device already found is a machine that can paint")
        expect(
            inherited.endpoint?.displayHost == "arch.taila1a09.ts.net:\(ForgeEndpoint.defaultPort)",
            "on the same door, because one ComfyUI holds both sets of models")
        expect(inherited.inherited, "and the lane says where the machine came from")
        expect(inherited.machine == "arch", "wearing the machine rather than the address")
        expect(inherited.line != nil, "an inherited machine is named before anybody has looked at it")

        let filed = ImageGenEndpoint(host: "studio", port: 9000)
        let chosen = ImageGenDoor.resolve(filed: filed, forge: arch)
        expect(chosen.endpoint == filed, "an address filed for pictures outranks the renderer's")
        expect(!chosen.inherited, "and does not claim to have come from it")

        expect(
            ImageGenEndpoint.read("arch") == .endpoint(ImageGenEndpoint(host: "arch")),
            "a bare machine name means ComfyUI's own port")
        expect(
            ImageGenEndpoint.read("http://arch:9001/")
                == .endpoint(ImageGenEndpoint(host: "arch", port: 9001)),
            "a pasted URL keeps the port it names")
        expect(ImageGenEndpoint.read("0.0.0.0:8188") == .bindAll, "and a bind address is refused")
        expect(
            ImageGenEndpoint.complaint(.bindAll) == ForgeEndpoint.complaint(.bindAll),
            "in the renderer's own words, because it is the same mistake about the same machine")

        let asleep = ImageGenSighting(
            host: inherited.endpoint?.displayHost ?? "", reachable: false)
        let dozing = ImageGenDoor.resolve(filed: nil, forge: arch, sighting: asleep)
        expect(
            dozing.isOpen,
            "a socket-activated machine that answered nothing is asleep, not gone — the lane stays")
        expect(dozing.line != nil, "and says so rather than pretending it is well")
        expect(dozing.tone == .quiet, "settled, because nothing is happening")

        let halfDressed = ImageGenSighting(
            host: inherited.endpoint?.displayHost ?? "", reachable: true,
            missingModels: ["vae/qwen_image_vae.safetensors"])
        expect(
            ImageGenDoor.resolve(filed: nil, forge: arch, sighting: halfDressed).tone == .attention,
            "a machine that is up and missing model files is the reader's to act on")
        expect(
            ImageGenDoor.resolve(filed: nil, forge: arch, sighting: halfDressed).line != nil,
            "and the missing files are counted out loud")

        let elsewhere = ImageGenSighting(host: "studio:9000", reachable: false)
        expect(
            ImageGenDoor.resolve(filed: nil, forge: arch, sighting: elsewhere).currentSighting == nil,
            "an answer filed against a machine nobody draws on says nothing about this one")
        expect(
            ImageGenDoor.resolve(filed: nil, forge: arch, sighting: elsewhere).tone == nil,
            "so it wears no mark it cannot justify")

        var slot = ImageGenSlot(endpoint: ImageGenEndpoint(host: "arch"))
        for field in ImageGenField.allCases {
            let before = slot.value(of: field)
            slot.advance(field)
            expect(slot.value(of: field) != before, "every chip walks to a different value")
        }
        expect(
            QuickAskLane.imageChips.count == ImageGenField.allCases.count,
            "the composer's chips and the slot's decisions are the same list")
        expect(
            QuickAskLane.image.sendLabel != QuickAskLane.chat.sendLabel,
            "the send control says it spends another machine's card")
        expect(QuickAskLane.image.needsRenderer, "and the lane knows it needs one")
        expect(!QuickAskLane.ask.needsRenderer, "while the ones that only need words do not")

        return failures
    }
}

/// How making a picture is reached, and what the control promises before it is pressed. The video
/// forge's own entry point, said about the other thing that machine does — one title, one SF
/// Symbol and one text glyph everywhere, so a menu row, a lane pill and a phone's button cannot
/// disagree about what they open.
public enum ImageGenEntryPoint {
    public static var title: String { Localized.text("Image") }

    /// The title on a menu row, where the ellipsis is the convention for "this opens something".
    public static var menuTitle: String { Localized.text("Image…") }

    public static var symbol: String { "photo.on.rectangle.angled" }

    public static var glyph: String { "◼" }

    /// What the control promises, which is a different promise before a renderer exists: one
    /// opens a box you describe a picture in, the other opens the setup that makes that possible.
    public static func tooltip(configured: Bool) -> String {
        configured
            ? Localized.text("Describe a picture and watch it be made")
            : Localized.text("Set up the machine that makes pictures")
    }

    public static func accessibilityLabel(painting: Bool) -> String {
        painting ? Localized.text("Image — rendering") : title
    }

    /// The mark the control wears while a picture is being made. Nil when nothing is — a badge on
    /// an idle control is a decoration, and this vocabulary has none.
    public static func activity(painting: Bool) -> ActivityKind? {
        painting ? .working : nil
    }
}

/// How the image surface is presented, which is the same argument the forge already settled.
///
/// Making a picture is a task you start, watch and collect. It is not a place you work, so it does
/// not earn half of a window the way a second conversation does — putting it in the tiling grid
/// spends the transcript's width on a surface nobody types into while it runs, and leaves the pane
/// behind afterwards. So it opens over the window and closes back to it, on every desk.
///
/// The one thing dismissal must not do is stop the render. The job lives above the surface, so
/// closing is closing a window rather than throwing away somebody else's card — and reopening
/// finds the same picture exactly where it was.
public enum ImageGenSurface {
    public static var title: String { ImageGenEntryPoint.title }

    public static var subtitle: String { ImageGenNotice.costLine }

    public static var dismissTitle: String { Localized.text("Done") }

    /// What closing means while something is being painted. Nil when nothing is — there is
    /// nothing to reassure anybody about.
    public static func dismissNote(painting: Bool) -> String? {
        guard painting else { return nil }
        return Localized.text(
            "Closing this leaves the picture rendering on the machine with the card. Come back and it will still be here."
        )
    }

    /// The size the modal opens at on a desktop, so a Mac sheet and a GTK window are the same
    /// surface rather than two shapes that share a name. Landscape: the picture is the room and
    /// the controls sit under it, which is how a studio is read rather than a form.
    public static let preferredWidth: Double = 1080
    public static let preferredHeight: Double = 680
    public static let minimumWidth: Double = 760
    public static let minimumHeight: Double = 500
}
