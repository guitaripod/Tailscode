import Foundation
import TailscodeCore

enum WatchStyleSection: Int, Hashable, CaseIterable {
    case preset, motion, moves, screen, wall, approvals

    var title: String? {
        switch self {
        case .preset: return nil
        case .motion: return String(localized: "Motion")
        case .moves: return String(localized: "Events that move")
        case .screen: return String(localized: "Screen")
        case .wall: return String(localized: "On the wall")
        case .approvals: return String(localized: "Approve from the wall")
        }
    }

    var rows: [WatchStyleRow] {
        switch self {
        case .preset: return [.preset]
        case .motion: return [.effects, .field, .light, .still]
        case .moves:
            return [
                .steps, .agents, .endings, .asks, .failures, .retries, .compaction, .arrivals,
            ]
        case .screen: return [.dim, .night, .keepAwake]
        case .wall: return [.clock, .hour, .rails, .squads]
        case .approvals: return [.approvals]
        }
    }
}

/// One option of a segmented or menu row, with the style that choosing it leads to.
struct WatchStyleChoice {
    let title: String
    let isSelected: Bool
    let result: (WallStyle) -> WallStyle
}

enum WatchStyleRow: String, Hashable {
    case preset, effects, field, light, still
    case steps, agents, endings, asks, failures, retries, compaction, arrivals
    case dim, night, keepAwake
    case clock, hour, rails, squads
    case approvals

    enum Control {
        case segmented, menu, toggle
    }

    var identifier: String { "watchstyle.\(rawValue)" }

    var title: String {
        switch self {
        case .preset: return String(localized: "Preset")
        case .effects: return String(localized: "Effects")
        case .field: return String(localized: "Field")
        case .light: return String(localized: "Light from tiles")
        case .still: return String(localized: "Still")
        case .steps: return String(localized: "A step lands")
        case .agents: return String(localized: "A sub-agent starts or ends")
        case .endings: return String(localized: "A turn ends")
        case .asks: return String(localized: "It needs you")
        case .failures: return String(localized: "Something fails")
        case .retries: return String(localized: "It retries or goes quiet")
        case .compaction: return String(localized: "Context is compacted")
        case .arrivals: return String(localized: "A session arrives or leaves")
        case .dim: return String(localized: "Dim when calm for")
        case .night: return String(localized: "Night")
        case .keepAwake: return String(localized: "Keep the screen on")
        case .clock: return String(localized: "Clock")
        case .hour: return String(localized: "Last hour")
        case .rails: return String(localized: "Recent and also running")
        case .squads: return String(localized: "Sub-agent tiles")
        case .approvals: return String(localized: "Approve from the wall")
        }
    }

    var control: Control {
        switch self {
        case .preset, .effects:
            return .segmented
        case .field, .dim, .night, .keepAwake, .approvals:
            return .menu
        case .light, .still, .steps, .agents, .endings, .asks, .failures, .retries, .compaction,
            .arrivals, .clock, .hour, .rails, .squads:
            return .toggle
        }
    }

    /// The switch a toggle row is bound to; nil for a row that chooses among options.
    var flag: WritableKeyPath<WallStyle, Bool>? {
        switch self {
        case .light: return \WallStyle.light
        case .still: return \WallStyle.still
        case .steps: return \WallStyle.moves.steps
        case .agents: return \WallStyle.moves.agents
        case .endings: return \WallStyle.moves.endings
        case .asks: return \WallStyle.moves.asks
        case .failures: return \WallStyle.moves.failures
        case .retries: return \WallStyle.moves.retries
        case .compaction: return \WallStyle.moves.compaction
        case .arrivals: return \WallStyle.moves.arrivals
        case .clock: return \WallStyle.showsClock
        case .hour: return \WallStyle.showsHour
        case .rails: return \WallStyle.showsRails
        case .squads: return \WallStyle.showsSquads
        case .preset, .effects, .field, .dim, .night, .keepAwake, .approvals: return nil
        }
    }

    func isOn(in style: WallStyle) -> Bool {
        guard let flag else { return false }
        return style[keyPath: flag]
    }

    var caption: String? {
        self == .still ? String(localized: "Also on when Reduce Motion is on") : nil
    }

    func detail(for style: WallStyle) -> String? {
        if self == .preset { return style.preset == .custom ? String(localized: "Custom") : nil }
        return caption
    }

    /// What the row says its setting is, for VoiceOver.
    func value(for style: WallStyle) -> String {
        switch control {
        case .toggle:
            return isOn(in: style) ? String(localized: "On") : String(localized: "Off")
        case .segmented, .menu:
            return choices(for: style).first { $0.isSelected }?.title ?? String(localized: "Custom")
        }
    }

    func choices(for style: WallStyle) -> [WatchStyleChoice] {
        switch self {
        case .preset:
            let presets: [(WallStyle.Preset, String)] = [
                (.studio, String(localized: "Studio")),
                (.nightDesk, String(localized: "Night desk")),
                (.showcase, String(localized: "Showcase")),
            ]
            return presets.map { preset, title in
                WatchStyleChoice(title: title, isSelected: style.preset == preset) { _ in
                    WallStyle.preset(preset)
                }
            }
        case .effects:
            return Self.choices(
                \WallStyle.effects, in: style,
                [
                    (.off, String(localized: "Off")), (.subtle, String(localized: "Subtle")),
                    (.lively, String(localized: "Lively")),
                ])
        case .field:
            return Self.choices(
                \WallStyle.field, in: style,
                [
                    (.motes, String(localized: "Motes")), (.currents, String(localized: "Currents")),
                    (.aurora, String(localized: "Aurora")), (.none, String(localized: "None")),
                ])
        case .dim:
            return Self.choices(
                \WallStyle.dimAfter, in: style, WallStyle.dimChoices.map { ($0, Self.dimTitle($0)) })
        case .night:
            return Self.choices(
                \WallStyle.night, in: style,
                [
                    (.off, String(localized: "Off")),
                    (.scheduled, String(localized: "22:00–07:00")),
                    (.always, String(localized: "Always")),
                ])
        case .keepAwake:
            return Self.choices(
                \WallStyle.keepAwake, in: style,
                [
                    (.whileCharging, String(localized: "While charging")),
                    (.always, String(localized: "Always")), (.never, String(localized: "Never")),
                ])
        case .approvals:
            return Self.choices(
                \WallStyle.approvals, in: style,
                [
                    (.hold, String(localized: "Hold, then Face ID")),
                    (.openChat, String(localized: "Open the chat")),
                ])
        case .light, .still, .steps, .agents, .endings, .asks, .failures, .retries, .compaction,
            .arrivals, .clock, .hour, .rails, .squads:
            return []
        }
    }

    private static func choices<Value: Equatable>(
        _ key: WritableKeyPath<WallStyle, Value>, in style: WallStyle,
        _ options: [(Value, String)]
    ) -> [WatchStyleChoice] {
        options.map { value, title in
            WatchStyleChoice(title: title, isSelected: style[keyPath: key] == value) { current in
                current.with { $0[keyPath: key] = value }
            }
        }
    }

    private static func dimTitle(_ interval: TimeInterval?) -> String {
        guard let interval else { return String(localized: "Never") }
        let minutes = Int((interval / 60).rounded())
        return String(localized: "\(minutes) min")
    }
}
