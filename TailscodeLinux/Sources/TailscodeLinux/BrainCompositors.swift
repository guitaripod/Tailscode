import CGtkShim
import Foundation
import TailscodeCore

/// The compositors the window's open brains draw with, shared between them.
///
/// A compositor holds the nine layers resampled to one size and the rest picture of the head in one
/// palette, which is most of what a brain costs to keep, so two brains of one size and one look —
/// two panes on the same chat, or the same turn opened twice — draw with one. Each brain still owns
/// its own pair of surfaces and the frame it last drew, and asks for its delta region explicitly,
/// so sharing never lets one brain's frame leak into another's. The decoded layers beneath are the
/// process's `NeuralAssetStore`, resident exactly while any compositor is.
///
/// Building one decodes and resamples the layers, which is tens of milliseconds on a warm store and
/// the better part of a second on a cold one, so it is made off the main loop and handed back there.
enum BrainCompositors {
    struct Key: Equatable {
        let width: Int
        let height: Int
        let table: NeuralToneTable
    }

    private final class Entry {
        let key: Key
        let compositor: NeuralCompositor
        var holders = 0
        var idleSince: Date?
        init(key: Key, compositor: NeuralCompositor) {
            self.key = key
            self.compositor = compositor
        }
    }

    private nonisolated(unsafe) static var entries: [Entry] = []
    private nonisolated(unsafe) static var building: [(Key, [(NeuralCompositor?) -> Void])] = []

    /// How many compositors the window holds right now, and how many brains hold them.
    static var resident: (compositors: Int, holders: Int) {
        (entries.count, entries.reduce(0) { $0 + $1.holders })
    }

    /// What the compositors hold in bytes, for the harness.
    static var footprint: Int {
        entries.reduce(0) { $0 + $1.compositor.memoryFootprint }
    }

    /// A compositor of this size and look, shared if one exists. `done` runs on the main loop with
    /// nil when a layer could not be loaded. Main loop only.
    static func acquire(
        width: Int, height: Int, table: NeuralToneTable, done: @escaping (NeuralCompositor?) -> Void
    ) {
        let key = Key(width: width, height: height, table: table)
        if let entry = entries.first(where: { $0.key == key }) {
            entry.holders += 1
            entry.idleSince = nil
            done(entry.compositor)
            return
        }
        if let index = building.firstIndex(where: { $0.0 == key }) {
            building[index].1.append(done)
            return
        }
        building.append((key, [done]))
        DispatchQueue.global(qos: .userInitiated).async {
            let compositor = NeuralCompositor(
                assets: .shared, size: (key.width, key.height), table: key.table)
            let usable = compositor.isComplete ? compositor : nil
            tailscode_malloc_trim()
            Gtk.onMain {
                guard let index = building.firstIndex(where: { $0.0 == key }) else { return }
                let waiting = building.remove(at: index).1
                guard let usable else {
                    for callback in waiting { callback(nil) }
                    return
                }
                let entry = Entry(key: key, compositor: usable)
                entry.holders = waiting.count
                entries.append(entry)
                for callback in waiting { callback(usable) }
            }
        }
    }

    /// How long a compositor nobody holds is kept. The head of a conversation is replaced by the
    /// next turn's every few minutes, and building one decodes nine pictures and resamples them,
    /// which leaves the allocator holding the transient copies; keeping the last one for a moment
    /// lets the next head take it, so a long session builds it once rather than once a turn.
    static let grace: TimeInterval = 8

    /// Lets go of a hold. The last holder's compositor is dropped, and with it the resampled
    /// layers, once nothing has asked for it again for ``grace`` seconds.
    static func release(_ compositor: NeuralCompositor) {
        guard let index = entries.firstIndex(where: { $0.compositor === compositor }) else { return }
        entries[index].holders -= 1
        guard entries[index].holders <= 0 else { return }
        entries[index].holders = 0
        let stamp = Date()
        entries[index].idleSince = stamp
        Gtk.after(UInt32(grace * 1000) + 100) {
            Gtk.onMain { dropIdle(olderThan: grace) }
        }
    }

    /// Drops every compositor nobody has held for `age` seconds, which a harness may ask for at
    /// once with zero.
    static func dropIdle(olderThan age: TimeInterval) {
        let now = Date()
        entries.removeAll { entry in
            guard entry.holders <= 0, let since = entry.idleSince else { return false }
            return now.timeIntervalSince(since) >= age - 0.05
        }
        if entries.isEmpty { tailscode_malloc_trim() }
    }
}
