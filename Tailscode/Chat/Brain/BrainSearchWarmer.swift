import Foundation
import QuartzCore

/// Reads the search text of a chat's brains for Find without holding the main thread: a slice of
/// at most `budget` seconds per run-loop turn, newest turn first. It stops when the chat cannot be
/// seen (the screen starts it again when it reappears) and after `cancel()`. Find's keystrokes read what has been indexed so far, and `finished`
/// runs once when every brain has been, so the matches are searched again with the rest.
@MainActor
final class BrainSearchWarmer {
    private weak var store: BrainStore?
    private let budget: TimeInterval
    private let isVisible: () -> Bool
    private let finished: () -> Void
    private var generation = 0
    private(set) var isWarm = false

    init(
        store: BrainStore, budget: TimeInterval = 0.002, isVisible: @escaping () -> Bool,
        finished: @escaping () -> Void
    ) {
        self.store = store
        self.budget = budget
        self.isVisible = isVisible
        self.finished = finished
    }

    func start() {
        generation += 1
        isWarm = false
        schedule(generation)
    }

    func cancel() {
        generation += 1
    }

    private func schedule(_ token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.generation else { return }
            self.slice(token)
        }
    }

    private func slice(_ token: Int) {
        guard let store else { return }
        guard isVisible() else { return }
        if store.indexSearch(budget: budget) {
            isWarm = true
            finished()
        } else {
            schedule(token)
        }
    }
}
