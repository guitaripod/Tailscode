import Foundation

/// A file the renderer wrote. ComfyUI hands back three fields and expects them handed straight
/// back on `/view`, so the asset is exactly those three and nothing derived — a URL built once and
/// stored would go stale the moment the endpoint moved, which it does every time somebody switches
/// between the tailnet name and the address.
public struct ForgeAsset: Sendable, Codable, Hashable {
    public let filename: String
    public let subfolder: String
    public let type: String

    public init(filename: String, subfolder: String = "", type: String = "output") {
        self.filename = filename
        self.subfolder = subfolder
        self.type = type
    }

    public func url(on endpoint: ForgeEndpoint) -> URL? {
        endpoint.url(
            "/view", query: ["filename": filename, "subfolder": subfolder, "type": type])
    }

    public var isVideo: Bool {
        let suffix = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "webm", "mov", "mkv"].contains(suffix)
    }

    /// What a graph on the same machine calls this file: ComfyUI's loaders read an annotated
    /// name — the path inside the directory, then the directory's kind in brackets — straight
    /// out of the directory the file was written to, so a clip continues into the next without
    /// a byte travelling.
    public var annotatedName: String {
        let path = subfolder.isEmpty ? filename : subfolder + "/" + filename
        return path + " [\(type)]"
    }

    /// The file inside a history entry's outputs. Public because the shape is the server's: it
    /// files a video under `images` with an `animated` flag beside it, which is exactly the sort of
    /// detail that changes in a point release, so a client's selftest pins it here. The save node
    /// is read first by its own key, because a graph that opens a clip to continue it reports the
    /// clip it opened as an output too — typed `input`, and not the file anybody asked for.
    public static func read(outputs: Any) -> ForgeAsset? {
        if let byNode = outputs as? [String: Any], let saved = byNode[ForgeGraph.outputKey],
            let asset = first(in: saved)
        {
            return asset
        }
        let found = all(in: outputs)
        return found.first { $0.type == "output" } ?? found.first
    }

    private static func first(in outputs: Any) -> ForgeAsset? {
        all(in: outputs).first
    }

    private static func all(in outputs: Any) -> [ForgeAsset] {
        var found: [ForgeAsset] = []
        var stack: [Any] = [outputs]
        while let next = stack.popLast() {
            if let object = next as? [String: Any] {
                if let filename = object["filename"] as? String, !filename.isEmpty {
                    found.append(
                        ForgeAsset(
                            filename: filename, subfolder: object["subfolder"] as? String ?? "",
                            type: object["type"] as? String ?? "output"))
                    continue
                }
                for key in object.keys.sorted(by: >) { stack.append(object[key]!) }
            } else if let list = next as? [Any] {
                stack.append(contentsOf: list.reversed())
            }
        }
        return found
    }
}

/// Where a generation is in its life. A render takes long enough that every one of these is a
/// distinct thing to say — the machine is being woken, the graph was accepted and is waiting its
/// turn, pixels are being made, it is done — and collapsing any two of them into "loading" is how
/// a person ends up staring at a bar that has not moved for twelve seconds wondering if they
/// pressed the button.
public enum ForgeJobPhase: Sendable, Equatable {
    case drafting
    case submitting
    /// How many jobs are ahead of this one. Zero means it is this job's turn.
    case queued(Int)
    case running(Double)
    case done(ForgeAsset)
    case failed(String)
    case cancelled
}

/// One generation, from the words somebody typed to the file that came back. Toolkit-free like
/// every model here: the client draws the phase and presses the buttons, and every word on screen
/// comes from this type so the phone, the Mac and the Linux desktop describe the same render the
/// same way.
public struct ForgeJob: Sendable, Equatable {
    public private(set) var recipe: ForgeRecipe
    public private(set) var phase: ForgeJobPhase
    public private(set) var promptID: String?
    /// How many nodes the graph that was posted has. The server's census names only the nodes
    /// it has touched, so five loaders finished and nothing yet running would read as a render
    /// that is done; the bar is finished over the whole graph, never over what has been seen.
    public private(set) var graphNodes: Int
    public private(set) var census: ForgeCensus?
    public private(set) var samplerStep: Int
    public private(set) var samplerSteps: Int
    public private(set) var startedAt: Date?
    /// When the machine actually began on it, as opposed to when it was asked. The queue and the
    /// wake are not the render, and an estimate learned from them would say every clip takes as
    /// long as the slowest morning.
    public private(set) var ranAt: Date?
    public private(set) var endedAt: Date?
    /// How long this render was expected to take when it was sent, learned from the ones before
    /// it on the same machine. Nil the first time.
    public private(set) var expected: TimeInterval?
    /// The machine's own sketch of the clip so far: the first frame of the latent, decoded after
    /// each sampler step. Nil until the first step and after the render ends.
    public private(set) var sketch: ImageGenPreviewFrame?
    /// The highest fraction reached. A census frame that counts fewer finished nodes than the last
    /// one is the server re-reporting, not the render going backwards, and a bar that retreats is
    /// read as a fault.
    private var reached: Double

    public init(recipe: ForgeRecipe = ForgeRecipe(), expected: TimeInterval? = nil) {
        self.recipe = recipe
        phase = .drafting
        promptID = nil
        graphNodes = 0
        census = nil
        samplerStep = 0
        samplerSteps = 0
        startedAt = nil
        ranAt = nil
        endedAt = nil
        self.expected = expected
        sketch = nil
        reached = 0
    }

    public mutating func revise(_ recipe: ForgeRecipe) {
        self.recipe = recipe
        if case .drafting = phase { return }
        draft()
    }

    /// Back to the box with what it was rendering still in it, so a clip somebody wants slightly
    /// different is one edit away rather than a retype.
    public mutating func draft() {
        phase = .drafting
        promptID = nil
        census = nil
        samplerStep = 0
        samplerSteps = 0
        startedAt = nil
        ranAt = nil
        endedAt = nil
        sketch = nil
        reached = 0
    }

    /// What the next render is expected to cost, told to a draft so the button under it can say
    /// so before anybody presses it.
    public mutating func expect(_ seconds: TimeInterval?) {
        expected = seconds
    }

    public mutating func submitting(at moment: Date = Date()) {
        phase = .submitting
        startedAt = moment
        endedAt = nil
        reached = 0
    }

    public mutating func accepted(
        promptID: String, queued: Int = 0, nodes: Int = 0, at moment: Date = Date()
    ) {
        self.promptID = promptID
        graphNodes = nodes
        startedAt = startedAt ?? moment
        phase = .queued(max(0, queued))
    }

    public mutating func delivered(_ asset: ForgeAsset, at moment: Date = Date()) {
        reached = 1
        endedAt = moment
        sketch = nil
        phase = .done(asset)
    }

    public mutating func failed(_ reason: String, at moment: Date = Date()) {
        endedAt = moment
        sketch = nil
        phase = .failed(reason)
    }

    public mutating func cancelled(at moment: Date = Date()) {
        endedAt = moment
        sketch = nil
        phase = .cancelled
    }

    /// Folds one frame off the socket into the job. Frames for other jobs on the same socket are
    /// dropped here rather than in every client, because a client that forgets to check will show
    /// somebody else's progress on this render and nobody will ever notice.
    public mutating func saw(_ event: ForgeEvent) {
        if let id = event.promptID, let mine = promptID, id != mine { return }
        switch event {
        case .status(let queued):
            guard case .queued = phase else { return }
            phase = .queued(max(0, queued - 1))
        case .started:
            ranAt = ranAt ?? Date()
            advance()
        case .cached:
            advance()
        case .progressed(_, let census):
            self.census = census
            let whole = max(census.total, graphNodes)
            let fraction = whole > 0 ? Double(census.finished) / Double(whole) : 0
            reached = max(reached, min(1, fraction))
            advance()
        case .sampling(_, _, let step, let steps):
            samplerStep = step
            samplerSteps = steps
            advance()
        case .executing, .executed:
            advance()
        case .sketched(let frame):
            guard isBusy else { return }
            sketch = frame
        case .finished, .succeeded:
            reached = 1
            advance()
        case .failed(_, let reason):
            failed(reason)
        case .interrupted:
            cancelled()
        case .ignored:
            return
        }
    }

    /// True once the server has said everything it is going to say and only the file is missing.
    /// The client answers it by asking history for the filename; the job stays honestly at full
    /// but unfinished until that lands.
    public var isCollecting: Bool {
        if case .running(let fraction) = phase { return fraction >= 1 }
        return false
    }

    public var isBusy: Bool {
        switch phase {
        case .submitting, .queued, .running: return true
        case .drafting, .done, .failed, .cancelled: return false
        }
    }

    public var isFinished: Bool {
        switch phase {
        case .done, .failed, .cancelled: return true
        case .drafting, .submitting, .queued, .running: return false
        }
    }

    public var asset: ForgeAsset? {
        if case .done(let asset) = phase { return asset }
        return nil
    }

    public var fraction: Double? {
        if case .running(let value) = phase { return value }
        return nil
    }

    public var percent: Int? {
        guard let fraction else { return nil }
        return Int((fraction * 100).rounded())
    }

    /// What the render is called: the words somebody typed, cut to a line. A generation with no
    /// prompt yet is still a row, so it says what it would be rather than being blank.
    public var title: String {
        let trimmed = recipe.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Localized.text("New video") }
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return line.count > 72 ? String(line.prefix(71)) + "…" : line
    }

    /// The line under the title: exactly what the render is doing, phase by phase. The waking
    /// sentence earns its place — the box is socket-activated and takes about twelve seconds to
    /// answer the first request of the day, and silence there is the single most likely moment for
    /// somebody to decide the app is broken.
    public var subtitle: String {
        switch phase {
        case .drafting:
            guard recipe.isRenderable else { return Localized.text("Describe the video") }
            guard let expected else { return Localized.text("Ready to render") }
            return Localized.text("Ready to render") + " · " + ForgeClock.aboutLine(expected)
        case .submitting:
            return Localized.text("Waking the renderer…")
        case .queued(let ahead):
            return ahead > 0
                ? Localized.text("%@ ahead in the queue", "\(ahead)")
                : Localized.text("Waiting its turn")
        case .running(let fraction):
            guard fraction < 1 else { return Localized.text("Saving the file…") }
            let line = Localized.text("Rendering · %@%%", "\(Int((fraction * 100).rounded()))")
            guard let left = remaining() else { return line }
            return line + " · " + left
        case .done:
            guard let spent = spent() else { return Localized.text("Ready") }
            return Localized.text("Ready · %@", spent)
        case .failed(let reason):
            return reason
        case .cancelled:
            return Localized.text("Stopped")
        }
    }

    /// One word for the row's corner. The percentage lives here while it runs, because a bar and a
    /// number saying different things is how a reader stops trusting either.
    public var badge: String? {
        switch phase {
        case .drafting: return nil
        case .submitting: return Localized.text("waking")
        case .queued: return Localized.text("queued")
        case .running(let fraction):
            guard fraction < 1 else { return Localized.text("saving") }
            return Localized.text("%@%%", "\(Int((fraction * 100).rounded()))")
        case .done: return Localized.text("ready")
        case .failed: return Localized.text("failed")
        case .cancelled: return Localized.text("stopped")
        }
    }

    /// The third line: what was asked for, and — while it renders — which of the two passes is
    /// working. The sampler step is said in words here precisely because it must never be the
    /// percentage: two passes means it counts to eight, resets, and counts to four.
    public var detail: String {
        guard isBusy, samplerSteps > 0 else { return recipe.summary }
        let step = Localized.text("step %@ of %@", "\(samplerStep)", "\(samplerSteps)")
        guard let stage = stageName else { return step }
        return "\(stage) · \(step)"
    }

    /// Which node the server says is working, said as a phrase rather than as a graph key.
    public var stageName: String? {
        guard let running = census?.running else { return nil }
        switch running {
        case "pass1": return Localized.text("First pass")
        case "up": return Localized.text("Upscaling")
        case "pass2": return Localized.text("Second pass")
        case "pixels", "audio": return Localized.text("Decoding")
        case "video", "save": return Localized.text("Writing the file")
        case "unet", "clip", "vae_v", "vae_a", "upscaler": return Localized.text("Loading models")
        case "pos", "neg", "cond": return Localized.text("Reading the prompt")
        case "still", "reel", "frames", "last", "prep", "start1", "start2":
            return Localized.text("Reading the start picture")
        default: return nil
        }
    }

    /// How long it took, or has taken. Seconds up to a minute, because a fast clip is twenty of
    /// them and "0m" is not an answer.
    public func spent(now: Date = Date()) -> String? {
        guard let startedAt else { return nil }
        let seconds = Int((endedAt ?? now).timeIntervalSince(startedAt).rounded())
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return Localized.text("%@s", "\(seconds)") }
        let minutes = seconds / 60
        let rest = seconds % 60
        return Localized.text("%@m %@s", "\(minutes)", "\(rest)")
    }

    /// How much longer, from the estimate and the clock, in words — or nothing, when there was
    /// no estimate or the render has already outrun it, because "0 s left" over a bar still
    /// moving is a lie a person catches at once.
    public func remaining(now: Date = Date()) -> String? {
        guard let expected, let since = ranAt ?? startedAt else { return nil }
        let left = expected - now.timeIntervalSince(since)
        guard left >= 1 else { return nil }
        return ForgeClock.leftLine(left)
    }

    /// How long the machine actually worked, for the clock to learn from: from the first frame
    /// the machine sent about this job to the last, and nothing when it never finished.
    public var worked: TimeInterval? {
        guard case .done = phase, let endedAt, let since = ranAt ?? startedAt else { return nil }
        let seconds = endedAt.timeIntervalSince(since)
        return seconds > 0 ? seconds : nil
    }

    public var prompt: String { Localized.text("Describe the video") }

    public var hint: String {
        Localized.text("enter renders · ctrl+c stops · esc goes back")
    }

    private mutating func advance() {
        switch phase {
        case .submitting, .queued:
            phase = .running(reached)
        case .running:
            phase = .running(reached)
        case .drafting, .done, .failed, .cancelled:
            return
        }
    }
}

extension ForgeJobPhase {
    /// The phase in the vocabulary every other surface in this app is drawn in. A phase that is
    /// doing something gets the activity's own motion — the wake sweeps, the queue holds still
    /// because waiting is settled, the card breathes while it works — and a phase that has stopped
    /// gets none at all, because stillness is how a reader tells a finished render from a slow one.
    public var activity: ActivityKind? {
        switch self {
        case .drafting, .done, .cancelled: return nil
        case .submitting: return .connecting
        case .queued(let ahead): return .queued(ahead)
        case .running: return .working
        case .failed: return .failed
        }
    }

    /// What colour the phase's word is worn in. Four meanings, none of them shared: work and a
    /// finished clip are the accent, a failure is the danger slot, and anything settled or waiting
    /// is quiet.
    public var tone: ActivityTone {
        switch self {
        case .drafting, .cancelled: return .quiet
        case .submitting, .queued: return .quiet
        case .running, .done: return .live
        case .failed: return .danger
        }
    }

    /// The face a stage with no picture in it shows — a symbol for the Apple clients, one glyph
    /// for the text ones. A render that never produced a frame still has a face: it is the
    /// difference between a card that failed and a card that is blank.
    public var stageSymbol: String {
        switch self {
        case .drafting, .submitting, .queued, .running: return "film"
        case .done: return "play.rectangle"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    public var stageGlyph: String {
        switch self {
        case .drafting, .submitting, .queued, .running: return "▭"
        case .done: return "▶"
        case .failed: return "✕"
        case .cancelled: return "■"
        }
    }
}
