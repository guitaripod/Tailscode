import Foundation
import Testing

@testable import TailscodeCore

/// The tiling chords live behind the ctrl+w prefix beside the vim ones, so the registry must take
/// them without a collision and resolve each to its action; the trailing writer must coalesce a
/// burst into one write and flush on demand; and a pane carried over a pane must resolve through
/// the chat drop's own zones.
@Suite("Tile shortcuts, writer and pane moves")
struct TileShortcutAndWriterTests {

    private static let table: [(id: String, defaults: [String], action: KeyAction)] = [
        ("split.cycle", ["ctrl+w w"], .cycleSplit(true)),
        ("split.cycleBack", ["ctrl+w shift+w"], .cycleSplit(false)),
        ("split.promote", ["ctrl+w return"], .promoteSplit),
        ("split.rotate", ["ctrl+w r"], .rotateSplits(true)),
        ("split.rotateBack", ["ctrl+w shift+r"], .rotateSplits(false)),
        ("split.moveFarLeft", ["ctrl+w shift+h"], .moveSplitToEdge(.left)),
        ("split.moveFarDown", ["ctrl+w shift+j"], .moveSplitToEdge(.down)),
        ("split.moveFarUp", ["ctrl+w shift+k"], .moveSplitToEdge(.up)),
        ("split.moveFarRight", ["ctrl+w shift+l"], .moveSplitToEdge(.right)),
        ("split.growWider", ["ctrl+w >"], .resizeSplit(.right)),
        ("split.growNarrower", ["ctrl+w <"], .resizeSplit(.left)),
        ("split.growTaller", ["ctrl+w +"], .resizeSplit(.down)),
        ("split.growShorter", ["ctrl+w -"], .resizeSplit(.up)),
        ("split.arrange", ["ctrl+w a"], .arrangeSplits),
        ("split.pin", [], .pinSplit),
        ("split.park", [], .parkSplit),
    ]

    @Test("Every tiling chord is registered as the table says, with no conflict")
    func chordsAreRegistered() throws {
        let set = ShortcutSet.build(overrides: [:])
        #expect(set.issues.isEmpty, "shortcut issues: \(set.issues)")
        for entry in Self.table {
            let definition = try #require(ShortcutRegistry.all.first { $0.id == entry.id })
            #expect(definition.defaults == entry.defaults, "\(entry.id)")
            #expect(definition.action == entry.action, "\(entry.id)")
            #expect(definition.contexts == [.normal], "\(entry.id)")
            for spec in entry.defaults {
                let parsed = try #require(KeySpec.parse(spec), "\(spec) does not parse")
                #expect(parsed.chords.count == 2)
            }
        }
        #expect(Set(ShortcutRegistry.all.map(\.id)).count == ShortcutRegistry.all.count)
    }

    @Test("The prefix then the key resolves to the action, the way a keyboard sends it")
    func chordsResolve() throws {
        let set = ShortcutSet.build(overrides: [:])
        let prefix = try #require(KeyChord.canonical(keyval: 0x77, state: KeyChord.controlMask))
        #expect(
            set.resolve(prefix, context: .normal, pending: [], awaitingApproval: false)
                == .pending([prefix]))
        func after(_ keyval: UInt32, _ state: UInt32 = 0) -> ShortcutSet.Resolution {
            let chord = KeyChord.canonical(keyval: keyval, state: state)!
            return set.resolve(chord, context: .normal, pending: [prefix], awaitingApproval: false)
        }
        #expect(after(0x77) == .run(.cycleSplit(true)))
        #expect(after(0x57, KeyChord.shiftMask) == .run(.cycleSplit(false)))
        #expect(after(Keymap.enter) == .run(.promoteSplit))
        #expect(after(Keymap.keypadEnter) == .run(.promoteSplit))
        #expect(after(0x52, KeyChord.shiftMask) == .run(.rotateSplits(false)))
        #expect(after(0x4C, KeyChord.shiftMask) == .run(.moveSplitToEdge(.right)))
        #expect(after(0x3E, KeyChord.shiftMask) == .run(.resizeSplit(.right)))
        #expect(after(0x3C, KeyChord.shiftMask) == .run(.resizeSplit(.left)))
        #expect(after(0x2B, KeyChord.shiftMask) == .run(.resizeSplit(.down)))
        #expect(after(0xFFAB) == .run(.resizeSplit(.down)))
        #expect(after(0x2D) == .run(.resizeSplit(.up)))
        #expect(after(0x61) == .run(.arrangeSplits))
        #expect(after(0x6C) == .run(.focusSplit(.right)))
    }

    @Test("The cheatsheet lists the bound chords and leaves the unbound ones out")
    func cheatsheetListsTheChords() {
        let set = ShortcutSet.build(overrides: [:])
        let rows = set.helpSections().flatMap(\.rows)
        let titles = Set(rows.map(\.what))
        for id in ["split.promote", "split.rotate", "split.arrange", "split.growWider", "split.cycle"] {
            let title = ShortcutRegistry.all.first { $0.id == id }!.title
            #expect(titles.contains(title), "\(id) missing from the cheatsheet")
        }
        #expect(set.effective["split.pin"] == [])
        #expect(set.effective["split.park"] == [])
        let pin = ShortcutRegistry.all.first { $0.id == "split.pin" }!.title
        #expect(!titles.contains(pin))
        let pinned = ShortcutSet.build(overrides: ["split.pin": ["ctrl+w p"]])
        #expect(pinned.issues.isEmpty)
        #expect(pinned.helpSections().flatMap(\.rows).contains { $0.what == pin })
    }

    @Test("A burst of schedules is one trailing write of the newest value")
    func writerCoalesces() async throws {
        let box = WrittenValues()
        let writer = TrailingWriter<Int>(delay: 0.05) { box.append($0) }
        for value in 1...20 { writer.schedule(value) }
        #expect(writer.hasPending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(box.values == ["20"])
        #expect(!writer.hasPending)
    }

    @Test("Flush writes what is waiting at once, and only once")
    func writerFlushes() async throws {
        let box = WrittenValues()
        let writer = TrailingWriter<String>(delay: 10) { box.append($0) }
        writer.schedule("a")
        writer.schedule("b")
        writer.flush()
        #expect(box.values == ["b"])
        writer.flush()
        #expect(box.values == ["b"])
        let quick = TrailingWriter<String>(delay: 0.02) { box.append($0) }
        quick.schedule("c")
        quick.flush()
        try await Task.sleep(for: .milliseconds(150))
        #expect(box.values == ["b", "c"])
    }

    @Test("A pane carried over a pane is aimed by the chat drop's zones")
    func paneMovesUseTheDropZones() throws {
        let pane = PaneID()
        let payload = PaneMovePayload(pane: pane)
        #expect(PaneMovePayload.identifier == "application/x-tailscode-pane")
        #expect(PaneMovePayload.decode(payload.encoded) == payload)
        #expect(PaneDragPayload.decode(payload.encoded) == nil)
        let chat = PaneDragPayload(profileID: "p", sessionID: "s")
        #expect(PaneMovePayload.decode(chat.encoded) == nil)
        #expect(PaneMovePayload.decode("tailscode-pane\t") == nil)

        var layout = try #require(SplitEven.layout(count: 3, as: .sideBySide))
        let ids = layout.paneIDs
        let middle = PaneDropTarget.zone(x: 300, y: 300, width: 600, height: 600)
        let edge = PaneDropTarget.zone(x: 590, y: 300, width: 600, height: 600)
        #expect(PaneDropTarget.move(ids[0], onto: ids[2], zone: middle) == .swap(ids[0], ids[2]))
        #expect(PaneDropTarget.move(ids[0], onto: ids[0], zone: middle) == nil)
        let intent = try #require(PaneDropTarget.move(ids[0], onto: ids[1], zone: edge))
        #expect(intent == .move(ids[0], onto: ids[1], edge: .right))

        let outcome1 = layout.apply(.swap(ids[0], ids[2]))
        #expect(outcome1)
        #expect(layout.paneIDs == [ids[2], ids[1], ids[0]])
        let outcome2 = layout.apply(intent)
        #expect(outcome2)
        #expect(layout.paneIDs == [ids[2], ids[1], ids[0]])
        #expect(layout.focusedPane == ids[0])
        #expect(PaneDropZone.fill.moveVerb != PaneDropZone.fill.verb)
        for edge in PaneDropEdge.allCases {
            #expect(!PaneDropZone.split(edge).moveVerb.isEmpty)
        }
    }
}

private final class WrittenValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [any Sendable] = []

    func append(_ value: any Sendable) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored.map { "\($0)" }
    }
}
