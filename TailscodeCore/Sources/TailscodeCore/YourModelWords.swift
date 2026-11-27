import Foundation

/// The model a person runs is the one `ImageGenStore.helper` files: one record on this device that
/// the Studio's briefs, and on Linux the wall's plain words, all read. This is that record seen as
/// a choice the person makes once, rather than as a setting of one surface.
public enum YourModelStore {
    public static var didChange: Notification.Name { ImageGenStore.didChange }

    public static func current() -> ImageGenHelper? { ImageGenStore.helper() }

    /// Files a model as the person's, keeping whether the Studio may use it.
    public static func choose(_ candidate: YourModelCandidate, byHand: Bool) {
        let studio = current()?.enabled ?? true
        ImageGenStore.remember(helper: candidate.helper(enabled: studio, chosenByHand: byHand))
    }

    /// Whether the Studio writes briefs out with it.
    public static func setStudio(_ on: Bool) {
        guard var held = current() else { return }
        held.enabled = on
        ImageGenStore.remember(helper: held)
    }

    /// Whether a model is filed at an address on this machine or the person's own network, which is
    /// where the privacy line can promise that nothing leaves.
    public static func isPrivate(_ helper: ImageGenHelper) -> Bool {
        PlainModel.endpoint(helper.address) != nil
    }

    /// The address plain words asks, which wants the `/v1` an OpenAI-shaped base carries.
    public static func plainWordsAddress(_ helper: ImageGenHelper) -> String {
        helper.address.hasSuffix("/v1") ? helper.address : helper.address + "/v1"
    }
}

/// Every word the Your model surfaces say, so the three clients say the same thing.
public enum YourModelWords {
    public static var title: String { Localized.text("Your model") }
    public static var thisDevice: String { Localized.text("This device") }

    public static var explainer: String {
        Localized.text(
            "A language model you run yourself, on this device or one of your machines. Tailscode finds it, proves it and lets it write for you."
        )
    }

    public static var looking: String { Localized.text("Looking for models on your machines…") }

    public static func lookingOn(_ machines: [String]) -> String {
        guard !machines.isEmpty else { return looking }
        return Localized.text("Looking on %@…", machines.joined(separator: ", "))
    }

    public static func found(models: Int, servers: Int) -> String {
        if servers == 1 {
            return models == 1 ? Localized.text("1 model on 1 server") : Localized.text("%d models on 1 server", models)
        }
        return Localized.text("%d models on %d servers", models, servers)
    }

    public static var noneTitle: String { Localized.text("No model server answered") }

    public static var noneBody: String {
        Localized.text(
            "Looked for Ollama, llama-swap, llama.cpp, LM Studio, vLLM, SGLang and others on this device and every machine your agents run on."
        )
    }

    public static var getOneTitle: String { Localized.text("Get one") }

    public static func getOneBody(_ server: String) -> String {
        Localized.text(
            "An agent on %@ can set up a small model there. It starts a new chat with the ask written out, and every step it takes is yours to approve.",
            server)
    }

    public static var getOneAction: String { Localized.text("Ask an agent to set one up") }
    public static var lookAgain: String { Localized.text("Look again") }
    public static var proveAgain: String { Localized.text("Ask again") }
    public static var loadAndAsk: String { Localized.text("Load and ask") }
    public static var notLoadedTitle: String { Localized.text("Not loaded") }
    public static var notFoundTitle: String { Localized.text("Not found just now") }

    public static var notFoundBody: String {
        Localized.text("Its server did not list it. Look again once that machine is up, or choose another below.")
    }
    public static var others: String { Localized.text("Models on your machines") }

    public static func proving(_ model: String) -> String {
        Localized.text("Asking %@ for two sentences…", model)
    }

    public static func provingFailed(_ reason: String) -> String {
        Localized.text("It did not answer: %@", reason)
    }

    public static func place(_ candidate: YourModelCandidate) -> String {
        let machine = inSentence(candidate.machine)
        guard let software = candidate.software else { return Localized.text("on %@", machine) }
        return Localized.text("on %@ · %@", machine, software)
    }

    public static func place(_ helper: ImageGenHelper) -> String {
        Localized.text("on %@", inSentence(machine(of: helper)))
    }

    static func machine(of helper: ImageGenHelper) -> String {
        YourModelSurvey.machineName(URLComponents(string: helper.address)?.host ?? helper.address)
    }

    /// A machine's name inside a sentence, where this device is not a heading.
    static func inSentence(_ machine: String) -> String {
        machine == thisDevice ? Localized.text("this device") : machine
    }

    /// What a model's state is, in the words a row shows beside it.
    public static func state(_ candidate: YourModelCandidate) -> String? {
        if candidate.pinned { return Localized.text("Kept warm") }
        if candidate.running == true { return Localized.text("Running") }
        if candidate.running == false { return Localized.text("Not loaded") }
        return nil
    }

    /// What using a model that is not loaded costs, said once where it is chosen.
    public static func caution(_ candidate: YourModelCandidate) -> String? {
        guard candidate.running == false else { return nil }
        if candidate.software == PlainModelScout.Kind.llamaSwap.title {
            return Localized.text("llama-swap loads it when asked, and may stop another model to make room")
        }
        return Localized.text("Its server loads it when asked, which takes a moment the first time")
    }

    /// The row's second line: the descriptor or id, the size and the state.
    public static func detail(_ candidate: YourModelCandidate) -> String {
        var parts: [String] = []
        if let detail = candidate.detail { parts.append(detail) } else if candidate.name != nil { parts.append(candidate.model) }
        if candidate.detail == nil, let size = candidate.parameters {
            parts.append(Localized.text("%@B", String(format: size < 10 ? "%.1f" : "%.0f", size)))
        }
        if let state = state(candidate) { parts.append(state) }
        return parts.joined(separator: " · ")
    }

    public static func defaultReason(_ candidate: YourModelCandidate) -> String {
        if candidate.pinned { return Localized.text("Chosen because %@ keeps it warm", candidate.software ?? candidate.machine) }
        if candidate.running == true { return Localized.text("Chosen because it is already running") }
        return Localized.text("Chosen as the best writer your machines have")
    }

    public static func seconds(_ value: TimeInterval) -> String {
        value < 1
            ? Localized.text("%d ms", Int((value * 1000).rounded()))
            : Localized.text("%@ s", String(format: "%.1f", value))
    }

    public static func privacy(_ helper: ImageGenHelper) -> String {
        let machine = inSentence(machine(of: helper))
        guard YourModelStore.isPrivate(helper) else {
            return Localized.text(
                "%@ is on the internet: what it is asked leaves your network. Choose a model on one of your own machines to keep it in.",
                machine)
        }
        return Localized.text(
            "What it is asked goes to %@ and nowhere else. Nothing is sent to the internet, and a command has its secrets taken out first.",
            machine)
    }

    public static var usesTitle: String { Localized.text("What it does for you") }
    public static var studioTitle: String { Localized.text("Write out picture and clip briefs") }

    public static var studioSubtitle: String {
        Localized.text("A few words in the Studio become the paragraph the painter was trained on. You see it and choose.")
    }

    public static var showMe: String { Localized.text("Show me") }
    public static var youType: String { Localized.text("You type") }
    public static var itWrites: String { Localized.text("It writes") }
    public static var rulesSay: String { Localized.text("The rules say") }
    public static var itSays: String { Localized.text("It says") }

    /// The start of a sample paragraph, enough to show what the model writes without the page
    /// growing by a screen.
    public static func excerpt(_ text: String, words limit: Int = 60) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > limit else { return text }
        return words.prefix(limit).joined(separator: " ") + " …"
    }

    /// The brief the Studio sample rewrites.
    public static var sampleBrief: String { Localized.text("a lighthouse in a storm") }

    /// A command no rule reads, for the wall's sample.
    public static let sampleCommand = "ffprobe -v error -show_entries format=duration -of csv=p=0 clip.mp4"

    public static var agentsTitle: String { Localized.text("Your agents") }

    public static func agentsOffer(_ servers: [String]) -> String {
        Localized.text("%@ can run it as an agent too.", servers.joined(separator: ", "))
    }

    public static var agentsNone: String {
        Localized.text("None of your agent servers lists it. omp and opencode can run a local model once their config names it.")
    }

    public static func suggestTitle(_ candidate: YourModelCandidate) -> String {
        candidate.pinned
            ? Localized.text("%@ is kept warm", candidate.label) : Localized.text("%@ is running", candidate.label)
    }

    public static var suggestBody: String { Localized.text("Use it instead and nothing has to load.") }
    public static func suggestAction(_ candidate: YourModelCandidate) -> String { Localized.text("Use %@", candidate.label) }

    public static var carry: String { Localized.text("Carry it in your party") }
    public static var carried: String { Localized.text("In your party") }
    public static var partyFull: String { Localized.text("Your party is full. Release a slot to carry it.") }

    public static var setUp: String { Localized.text("Set up your model") }
    public static var menuTitle: String { Localized.text("Your model…") }
    public static var menuHint: String { Localized.text("Find, prove and choose the model you run, and what it does") }
}
