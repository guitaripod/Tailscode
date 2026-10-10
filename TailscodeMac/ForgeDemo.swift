import Foundation
import TailscodeCore

/// The forge's states as values, built from Core's own mutators rather than described in words this
/// client invented. It is a plain function of a name so the selftest can assert what each state
/// says without a window, and the Studio can put the same state on screen for a picture.
enum ForgeDemo {
    static let host = "arch"
    static let promptID = "demo"
    static let prompt = "a cat asleep on a warm tiled roof, late afternoon light"
    static let avoidance = "blurry, jitter"
    static let asset = ForgeAsset(filename: "forge_00007.mp4", subfolder: "video", type: "output")

    /// Every name this understands, which is also the list `--open forge:<state>` accepts.
    static let states = [
        "unset", "checking", "down", "ready", "waking", "queued", "running", "collecting", "done",
        "failed", "stopped", "empty", "history",
    ]

    static func board(_ name: String) -> ForgeBoard {
        let recipe = ForgeRecipe(
            prompt: name == "unset" ? "" : prompt, negative: avoidance, width: 1280, height: 704,
            seconds: 5, fps: 24, seed: 481_723)
        var board = ForgeBoard(
            recipe: recipe, endpoint: name == "unset" ? nil : ForgeEndpoint(host: host))
        switch name {
        case "unset":
            board.filled(history: [])
        case "checking":
            board.checking()
            board.filled(history: [])
        case "down":
            board.reached(.timedOut)
            board.filled(history: [])
        case "empty":
            board.reached(.listening)
            board.filled(history: [])
        case "history", "ready":
            board.reached(.listening)
            board.filled(history: history(recipe))
        default:
            board.reached(.listening)
            board.saw(job(name, recipe: recipe))
            board.filled(history: history(recipe))
        }
        return board
    }

    private static func job(_ name: String, recipe: ForgeRecipe) -> ForgeJob {
        var job = ForgeJob(recipe: recipe)
        job.submitting(at: Date().addingTimeInterval(-74))
        guard name != "waking" else { return job }
        job.accepted(promptID: promptID, queued: 2)
        guard name != "queued" else { return job }
        switch name {
        case "failed":
            job.saw(.failed(promptID, reason: "UNETLoader failed: CUDA out of memory"))
        case "stopped":
            job.saw(.interrupted(promptID))
        case "collecting", "done":
            job.saw(
                .progressed(promptID, census: ForgeCensus(finished: 27, total: 28, running: "save")))
            job.saw(.finished(promptID))
            if name == "done" { job.delivered(asset) }
        default:
            job.saw(.started(promptID))
            job.saw(
                .progressed(promptID, census: ForgeCensus(finished: 14, total: 28, running: "pass2")))
            job.saw(.sampling(promptID, node: "pass2", step: 3, steps: 4))
        }
        return job
    }

    /// Six clips that came back and one that never did, newest first the way the store files them.
    /// The one that never did leads, because a history where every visible row succeeded proves
    /// nothing about the row that has to say why one of them did not.
    static func history(_ recipe: ForgeRecipe) -> [ForgeEntry] {
        let words = [
            "a cat asleep on a warm tiled roof, late afternoon light",
            "rain on a neon street, shallow depth of field",
            "a paper boat going over a weir in slow motion",
            "a lighthouse beam sweeping fog",
            "a hand turning the page of an old atlas",
            "steam rising off a cup on a cold morning",
        ]
        let made = words.enumerated().map { index, words in
            ForgeEntry(
                id: "\(promptID)-\(index)",
                recipe: recipe.with(prompt: words).with(seed: 1000 + index),
                asset: ForgeAsset(filename: "forge_0000\(index).mp4", subfolder: "video"),
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 3600))
        }
        let lost = ForgeEntry(
            id: "\(promptID)-lost", recipe: recipe.with(seed: 9), asset: nil,
            failure: ForgeFailure.noOutput(host).description,
            finishedAt: Date(timeIntervalSince1970: 1_700_003_600))
        return [lost] + made
    }
}
