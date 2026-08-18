import CodingAgentKit
import Foundation

/// What the model a turn will run on can actually be handed, and how hard it can be asked to think.
///
/// A capability is a property of the model far more often than of the server: one opencode machine
/// fronts a hundred models, half of which cannot see a picture and most of which take no effort
/// level at all. So the affordances follow the *pick*, not the connection — a surface offers an
/// errand only where the errand can be carried out, because a control that leads to "this model
/// can't read that" is worse than a control that was never drawn, and a level nobody can pick reads
/// as a default nobody set.
///
/// Every client asks these two the same question about the same catalog, so the composer, the quick
/// ask, the paste and the drop can never disagree about one model.

/// What the aim can be handed.
public struct ModelAbilities: Sendable, Equatable {
    public var attachments: Bool
    public var vision: Bool
    /// Whether this device has a camera to point at something. A fact about the machine holding
    /// the surface, not about the machine answering it.
    public var camera: Bool

    public init(attachments: Bool = false, vision: Bool = false, camera: Bool = false) {
        self.attachments = attachments
        self.vision = vision
        self.camera = camera
    }

    /// Words only — the honest answer for a backend that takes nothing but a prompt.
    public static let words = ModelAbilities()

    /// The backend's word narrowed by the model's own, which is the only one that decides whether
    /// a picture can be read. A model the catalog cannot describe is trusted to the backend rather
    /// than assumed blind: a server that never published per-model capabilities must not lose its
    /// attach affordance over a fact nobody stated.
    public static func resolve(
        supportsAttachments: Bool, model: ModelCapabilities?, camera: Bool = false
    ) -> ModelAbilities {
        guard supportsAttachments else { return ModelAbilities(camera: false) }
        guard let model else {
            return ModelAbilities(attachments: true, vision: true, camera: camera)
        }
        return ModelAbilities(
            attachments: model.attachment, vision: model.attachment && model.imageInput,
            camera: camera && model.attachment && model.imageInput)
    }

    /// The same answer from a catalog and a pick, which is the shape a composer actually holds.
    /// A pick with no provider — the shape a chat carries when the model came from the server's
    /// own session record rather than from this device's catalog — matches on the id alone, so a
    /// reopened conversation is not treated as a model nobody can describe.
    public static func resolve(
        supportsAttachments: Bool, models: [ModelInfo], selection: ModelSelection?,
        camera: Bool = false
    ) -> ModelAbilities {
        resolve(
            supportsAttachments: supportsAttachments,
            model: capabilities(of: selection, in: models), camera: camera)
    }

    public static func capabilities(
        of selection: ModelSelection?, in models: [ModelInfo]
    ) -> ModelCapabilities? {
        guard let selection else { return nil }
        let exact = models.first {
            $0.providerID == selection.providerID && $0.id == selection.modelID
        }
        return (exact ?? models.first { $0.id == selection.modelID })?.capabilities
    }

    /// Whether an attachment already in hand may still go out. A model switch mid-compose is the
    /// one way a picture becomes unsendable after it was picked, and the surface has to drop it
    /// rather than let the send fail on the other machine.
    public func accepts(mime: String) -> Bool {
        guard attachments else { return false }
        return vision || !mime.hasPrefix("image/")
    }

    /// What to say when a switch just made something in hand unsendable. Said out loud rather than
    /// dropped quietly: a picture that disappears from a composer with no word is the app losing
    /// work, whatever the reason was.
    public static func dropped(_ count: Int) -> String {
        count == 1
            ? Localized.text("Picture removed — this model can't see images.")
            : Localized.text("%d pictures removed — this model can't see images.", count)
    }

    /// The one line a surface shows where the attach affordance is missing, so its absence is a
    /// stated fact rather than a control somebody assumes they failed to find.
    public func unavailableReason(supportsAttachments: Bool) -> String? {
        guard !attachments else { return nil }
        return supportsAttachments
            ? Localized.text("This model takes no attachments")
            : Localized.text("This server does not take attachments")
    }
}

/// How hard the machine is asked to think.
///
/// Effort is a property of the model where the catalog says so — the picked model's own variants —
/// and a property of the agent otherwise. Every surface that offers a level reads it from here, so
/// the chat composer, the quick ask and a command can never offer different levels for one aim.
public enum ModelEffort {
    public static func options(
        models: [ModelInfo], selection: ModelSelection?, agentOptions: [String]
    ) -> [String] {
        guard let selection,
            let model = models.first(where: {
                $0.providerID == selection.providerID && $0.id == selection.modelID
            })
        else { return agentOptions }
        // nil variants = the catalog did not say → agent list. Empty = this model has none.
        guard let variants = model.variants else { return agentOptions }
        return variants
    }

    /// The levels for a model named only by its id — what a chat holds once the server's session
    /// record, rather than this device's pick, is what says which model is running. A catalog that
    /// names the model without variants is a catalog saying it has none, so the agent's list is
    /// used only where the model itself is unknown.
    public static func options(
        models: [ModelInfo], modelID: String?, agentOptions: [String]
    ) -> [String] {
        guard let modelID, let model = models.first(where: { $0.id == modelID }) else {
            return agentOptions
        }
        guard let variants = model.variants else { return agentOptions }
        return variants
    }

    /// What the control says. A level picked by hand is the word itself; nothing picked is the
    /// server deciding, which is a real answer rather than a blank.
    ///
    /// Nil where there is nothing to offer: a model with no levels has no effort control, and the
    /// old answer — a pill reading "no effort control" — spent a permanent slot in the chrome
    /// explaining the absence of something nobody asked for.
    public static func label(_ level: String?, options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        if let level, !level.isEmpty { return level }
        return Localized.text("server effort")
    }

    /// Whether the control is worth drawing at all.
    public static func isOffered(options: [String]) -> Bool { !options.isEmpty }

    /// A level the picked model cannot run is handed back to the machine rather than kept as a
    /// word the send would not carry.
    public static func surviving(_ level: String?, options: [String]) -> String? {
        guard let level, options.contains(level) else { return nil }
        return level
    }

    /// What effort becomes after a model pick. Keep the level only where the new model offers it;
    /// otherwise hand it back to the server. Every surface that changes the model runs the level
    /// through here, so a stranded "max" can never stay named, checked nowhere, and shipped with
    /// the next prompt.
    public static func adopt(_ level: String?, for selection: ModelSelection?, models: [ModelInfo],
        agentOptions: [String]
    ) -> String? {
        surviving(level, options: options(models: models, selection: selection, agentOptions: agentOptions))
    }

    public static func adopt(
        _ level: String?, modelID: String?, models: [ModelInfo], agentOptions: [String]
    ) -> String? {
        surviving(level, options: options(models: models, modelID: modelID, agentOptions: agentOptions))
    }
}
