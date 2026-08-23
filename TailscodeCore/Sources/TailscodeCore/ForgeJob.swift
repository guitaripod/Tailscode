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

    /// The file inside a history entry's outputs. Public because the shape is the server's: it
    /// files a video under `images` with an `animated` flag beside it, which is exactly the sort of
    /// detail that changes in a point release, so a client's selftest pins it here.
    public static func read(outputs: Any) -> ForgeAsset? {
        var stack: [Any] = [outputs]
        while let next = stack.popLast() {
            if let object = next as? [String: Any] {
                if let filename = object["filename"] as? String, !filename.isEmpty {
                    return ForgeAsset(
                        filename: filename, subfolder: object["subfolder"] as? String ?? "",
                        type: object["type"] as? String ?? "output")
                }
                stack.append(contentsOf: object.values)
            } else if let list = next as? [Any] {
                stack.append(contentsOf: list)
            }
        }
        return nil
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
    public private(set) var census: ForgeCensus?
    public private(set) var samplerStep: Int
    public private(set) var samplerSteps: Int
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    /// The highest fraction reached. A census frame that counts fewer finished nodes than the last
    /// one is the server re-reporting, not the render going backwards, and a bar that retreats is
    /// read as a fault.
    private var reached: Double

    public init(recipe: ForgeRecipe = ForgeRecipe()) {
        self.recipe = recipe
        phase = .drafting
        promptID = nil
        census = nil
        samplerStep = 0
        samplerSteps = 0
        startedAt = nil
        endedAt = nil
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
        endedAt = nil
        reached = 0
    }

    public mutating func submitting(at moment: Date = Date()) {
        phase = .submitting
        startedAt = moment
        endedAt = nil
        reached = 0
    }

    public mutating func accepted(promptID: String, queued: Int = 0, at moment: Date = Date()) {
        self.promptID = promptID
        startedAt = startedAt ?? moment
        phase = .queued(max(0, queued))
    }

    public mutating func delivered(_ asset: ForgeAsset, at moment: Date = Date()) {
        reached = 1
        endedAt = moment
        phase = .done(asset)
    }

    public mutating func failed(_ reason: String, at moment: Date = Date()) {
        endedAt = moment
        phase = .failed(reason)
    }

    public mutating func cancelled(at moment: Date = Date()) {
        endedAt = moment
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
            advance()
        case .cached:
            advance()
        case .progressed(_, let census):
            self.census = census
            reached = max(reached, census.fraction)
            advance()
        case .sampling(_, _, let step, let steps):
            samplerStep = step
            samplerSteps = steps
            advance()
        case .executing, .executed:
            advance()
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
            return recipe.isRenderable
                ? Localized.text("Ready to render") : Localized.text("Describe the video")
        case .submitting:
            return Localized.text("Waking the renderer…")
        case .queued(let ahead):
            return ahead > 0
                ? Localized.text("%@ ahead in the queue", "\(ahead)")
                : Localized.text("Waiting its turn")
        case .running(let fraction):
            guard fraction < 1 else { return Localized.text("Saving the file…") }
            return Localized.text("Rendering · %@%%", "\(Int((fraction * 100).rounded()))")
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
