import Foundation

/// The pane verbs as a menu, so a desktop that offers them names them in one order under one set of
/// headings and a person who never learns the chords still reaches every one. Titles and chords
/// are the registry's own; this only says which verbs, grouped how.
public enum SplitMenu {
    public struct Group: Sendable, Equatable {
        public let title: String
        public let shortcutIDs: [String]
    }

    /// Arrange, move, resize: what changes the shape, what changes which slot a pane holds, and
    /// what changes how much room it has.
    public static let groups: [Group] = [
        Group(
            title: Localized.text("Arrange"),
            shortcutIDs: ["split.arrange", "split.promote", "split.rotate", "split.rotateBack"]),
        Group(
            title: Localized.text("Move"),
            shortcutIDs: [
                "split.moveFarLeft", "split.moveFarDown", "split.moveFarUp", "split.moveFarRight",
            ]),
        Group(
            title: Localized.text("Resize"),
            shortcutIDs: [
                "split.growWider", "split.growNarrower", "split.growTaller", "split.growShorter",
            ]),
    ]

    /// Every arrangement a menu may name directly: the cycle's four and main on top, which the
    /// cycle does not reach.
    public static let arrangements: [SplitArrangement] = SplitArrangement.allCases

    public static func definition(_ shortcutID: String) -> ShortcutDefinition? {
        ShortcutRegistry.all.first { $0.id == shortcutID }
    }
}
