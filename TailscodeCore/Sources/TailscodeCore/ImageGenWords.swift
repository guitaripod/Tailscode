import Foundation

/// What a picture cost and what made it, said as facts rather than as a caption. The words are
/// Core's so a Mac, a phone and a GTK pane cannot each round the seconds differently.
public enum ImageGenFacts {
    public static func line(for picture: ImageGenPicture) -> String {
        let seconds =
            picture.seconds < 10
            ? String(format: "%.1f s", picture.seconds)
            : "\(Int(picture.seconds.rounded())) s"
        var parts = [picture.engine.short, picture.aspect.label(picture.size), seconds]
        if let steps = picture.steps { parts.append(Localized.text("%@ steps", "\(steps)")) }
        parts.append(seedMark(picture.seed))
        return parts.joined(separator: " · ")
    }

    /// A seed is twenty digits and a fact line is one line. What a person does with a seed is
    /// recognise it and copy it whole from the viewer, so the mark shows both ends rather than
    /// spending the row on the middle.
    public static func seedMark(_ seed: UInt64) -> String {
        let digits = "\(seed)"
        guard digits.count > 12 else { return "#" + digits }
        return "#\(digits.prefix(4))…\(digits.suffix(4))"
    }

    /// The words that made it, which is the one thing worth reading before the facts.
    public static func caption(for picture: ImageGenPicture) -> String { picture.prompt }

    /// The same two lines for a picture the machine keeps, read from its file rather than from a
    /// render this device remembers: what is known is said and what is not is left out, so a
    /// foreign file reads as its size and its day rather than as a row of zeros.
    public static func caption(for facts: ImageGenLibraryFacts?) -> String {
        guard let words = facts?.recipe?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !words.isEmpty
        else { return ImageGenLibraryWords.noWords }
        return words
    }

    public static func line(for facts: ImageGenLibraryFacts?, now: Date = Date()) -> String {
        guard let facts else { return "" }
        var parts: [String] = []
        if let engine = facts.recipe?.engine {
            parts.append(engine.short)
        } else if let model = facts.recipe?.model {
            parts.append((model as NSString).deletingPathExtension)
        }
        if let dimensions = facts.dimensions { parts.append(dimensions) }
        if let steps = facts.recipe?.steps { parts.append(Localized.text("%@ steps", "\(steps)")) }
        if let seed = facts.recipe?.seed { parts.append(seedMark(seed)) }
        if let date = facts.modifiedAt { parts.append(ImageGenLibraryWords.day(date, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// A file's size in the unit a person reads it in.
    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// A name to offer the desktop's save dialog: the words, made into a filename, so a folder of
    /// these reads as what they are rather than as a row of timestamps.
    public static func fileName(for picture: ImageGenPicture) -> String {
        let allowed = picture.prompt.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let squashed = String(allowed).split(separator: "-").prefix(6).joined(separator: "-")
        let stem = squashed.isEmpty ? "image" : squashed
        return "\(stem).png"
    }
}

/// Every word the image surface says that is not a field, an action or a fact. Held here so a
/// client draws a studio rather than inventing one.
public enum ImageGenWords {
    /// The button that starts a render, which says which of the two things it is about to do.
    public static func renderTitle(mode: ImageGenMode) -> String {
        mode == .edit ? Localized.text("Edit") : Localized.text("Generate")
    }

    public static var stopTitle: String { Localized.text("Stop") }

    public static var attachTitle: String { Localized.text("Add a reference") }

    public static var attachHint: String {
        Localized.text("Start the render from a picture instead of from words alone")
    }

    /// Once one picture is held, the chip is about the next one rather than about the idea.
    public static var attachMoreTitle: String { Localized.text("Add another") }

    public static var attachMoreHint: String {
        Localized.text("The words address them in order: <image1>, <image2>, and so on")
    }

    public static func attachedCount(_ count: Int) -> String {
        Localized.text("%@ references", "\(count)")
    }

    public static func referenceSlot(_ index: Int) -> String { "<image\(index)>" }

    public static func releaseHint(_ name: String) -> String {
        Localized.text("Let go of %@", name)
    }

    public static var addressHint: String {
        Localized.text("Name them in the words: <image1>, <image2>")
    }

    /// The second row of decisions, which stays shut for the people who never need it.
    public static var moreTitle: String { Localized.text("More") }

    public static var lessTitle: String { Localized.text("Less") }

    public static var cutoutTitle: String { Localized.text("Cutout") }

    public static var cutoutHint: String {
        Localized.text("Paint on transparency rather than on a background")
    }

    public static var seedHeldHint: String {
        Localized.text("Held — change a word and only that word changes. Press to roll again")
    }

    public static var seedRollsHint: String {
        Localized.text("Every render rolls a new number. Press to hold the last one")
    }

    public static var enhanceTitle: String { Localized.text("Enhance") }

    public static var enhancingTitle: String { Localized.text("Enhancing…") }

    /// What the chip promises before it is pressed, said as what it does rather than as magic.
    public static func enhanceHint(_ helper: ImageGenHelper) -> String {
        Localized.text("Rewrite the brief with %@ on %@", helper.chip, helper.displayHost)
    }

    public static var enhanceLookingTitle: String { Localized.text("Find a prompt helper") }

    public static var enhanceLookingHint: String {
        Localized.text("Looks for Ollama, llama-swap, llama.cpp or LM Studio on the machine")
    }

    /// The one word beside a helper's name when it is filed but switched off.
    public static var offMark: String { Localized.text("off") }

    public static var enhanceMissing: String {
        Localized.text("No prompt helper found. Anything OpenAI-shaped will do")
    }

    public static func enhancedNotice(_ helper: ImageGenHelper) -> String {
        Localized.text("Brief rewritten by %@", helper.chip)
    }

    public static var undoTitle: String { Localized.text("Undo") }

    public static var helperTitle: String { Localized.text("Helper") }

    public static var helperOffTitle: String { Localized.text("Do not rewrite briefs") }

    public static var helperOffHint: String {
        Localized.text("The studio keeps teaching the shape; it stops writing it")
    }

    public static var avoidTitle: String { Localized.text("Avoid") }

    public static var avoidHint: String {
        Localized.text(
            "Words the render keeps out. It raises guidance to make them count, so the picture "
                + "takes longer.")
    }

    public static var applyTitle: String { Localized.text("Apply") }

    public static var cancelTitle: String { Localized.text("Cancel") }

    public static var avoidPlaceholder: String {
        Localized.text("Avoid… (raises guidance, so the render takes longer)")
    }

    public static var scaffoldTitle: String { Localized.text("Use a frame") }

    public static var scaffoldHint: String {
        Localized.text("Fills the box with the shape to complete. Nothing is sent")
    }

    public static var examplePrefix: String { Localized.text("Example ·") }

    /// What the attached picture's chip promises when it is let go of.
    public static var detachHint: String { Localized.text("Render from words alone again") }

    public static func referenceHint(_ reference: ImageGenReference) -> String {
        Localized.text("Editing %@ — the next render starts from it", reference.name)
    }

    /// The empty stage, which argues for itself rather than showing a grey rectangle.
    public static var emptyTitle: String { Localized.text("Nothing painted yet") }

    public static var emptyBody: String {
        Localized.text("Describe a picture below. It is painted on the machine with the card.")
    }

    /// What the strip of everything made so far is called once there is more than one.
    public static func historyTitle(count: Int) -> String {
        count == 1
            ? Localized.text("1 picture this session")
            : Localized.text("%@ pictures this session", "\(count)")
    }

    public static func savedNotice(path: String) -> String {
        Localized.text("Saved to %@", path)
    }

    public static var copiedNotice: String { Localized.text("Picture copied") }

    /// The way back out of full size, said in the surface rather than left to be guessed — a
    /// picture filling the room has hidden every other control, so the one that returns is the
    /// one thing that has to still be legible.
    public static var zoomHint: String {
        Localized.text("Click the picture or press Esc to go back")
    }

    public static var discardNotice: String { Localized.text("Picture let go of") }

    /// Why the aspect chip is not offered while a reference is held.
    public static var aspectFollowsReference: String {
        Localized.text("Size follows the reference")
    }

    public static var replaceReference: String { Localized.text("Replace…") }

    public static var removeReference: String { Localized.text("Remove") }

    /// The engine chip's own note when the machine, as last seen, lacks that engine's files.
    public static func engineUnavailable(_ engine: ImageGenEngine, missing: Int) -> String {
        missing == 1
            ? Localized.text("%@ is missing 1 of its model files", engine.label)
            : Localized.text("%@ is missing %@ of its model files", engine.label, "\(missing)")
    }

    /// What the render button says when it cannot honestly start: the engine's files are not on
    /// the machine, said before a queue error would have said it worse.
    public static func cannotRender(
        engine: ImageGenEngine, machine: String, missing: [ImageGenModelFile] = []
    ) -> String {
        let files = missing.compactMap { MediaRequirements.file(named: $0.name) }
        if !files.isEmpty { return MediaReading.filesSentence(files, lane: .pictures) }
        return Localized.text(
            "%@ is not set up for %@ — its model files are missing. Choose the other engine or add the files.",
            machine, engine.label)
    }

    public static var stoppedNotice: String { Localized.text("Stopped") }

    /// The picture on the stage is one the machine kept rather than one made here: said once, under
    /// the facts, so a reader knows the words came from the file.
    public static var keptNote: String { ImageGenLibraryWords.fromLibraryHint }

    public static var stageEmptyKept: String {
        Localized.text(
            "Describe a picture below, or press and hold one on the shelf to start from it.")
    }

    /// The one control that takes the studio back to blank: the stage, the reference, a failure
    /// and the words all go; the pictures stay on the shelf and in the session.
    public static var startOver: String { Localized.text("Start over") }

    public static var startOverHint: String {
        Localized.text("Clear the stage, the reference and the words. Every picture stays on the shelf.")
    }
}

/// The machine sheet: everything the picture machine has said about itself, on one surface, with
/// the two things a person does there — look again, and point somewhere else. Every word is here so
/// a phone and a desk describe the same machine the same way.
public enum ImageGenMachineWords {
    public static var title: String { Localized.text("Machine") }

    public static var addressLabel: String { Localized.text("Address") }

    public static var versionLabel: String { Localized.text("ComfyUI") }

    public static var checkedLabel: String { Localized.text("Last checked") }

    public static var queueLabel: String { Localized.text("Queue") }

    public static var modelsTitle: String { Localized.text("Model files") }

    public static var checkAgain: String { Localized.text("Check again") }

    public static var checking: String { Localized.text("Checking…") }

    public static var change: String { Localized.text("Change machine…") }

    public static var neverChecked: String { Localized.text("Not checked yet") }

    public static var inherited: String {
        Localized.text("Shared with the video renderer — one ComfyUI holds both sets of models.")
    }

    public static func queue(running: Int) -> String {
        switch running {
        case 0: return Localized.text("Idle")
        case 1: return Localized.text("1 render running")
        default: return Localized.text("%@ renders running", "\(running)")
        }
    }

    public static var present: String { Localized.text("Present") }

    public static var missing: String { Localized.text("Missing") }

    public static var unknown: String { Localized.text("Unknown") }

    /// One sentence for the whole machine, which is what a header wears.
    public static func summary(_ sighting: ImageGenSighting?) -> String {
        guard let sighting else { return neverChecked }
        guard sighting.reachable else { return Localized.text("Not answering when last checked") }
        let ready = ImageGenEngine.allCases.filter(sighting.available)
        switch ready.count {
        case ImageGenEngine.allCases.count: return Localized.text("Ready · both engines")
        case 0: return Localized.text("Answering, but no engine has all its files")
        default:
            return Localized.text(
                "Ready for %@ only", ready.map(\.label).joined(separator: ", "))
        }
    }
}
