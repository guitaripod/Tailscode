import TailscodeCore
import UIKit

/// How an agent's tone and motion become the mark every other list in the app wears: the same
/// `ActivityIcon` and `ActivityBadgeView`, so a working row here breathes in step with the one on
/// Home, and stillness still means settled.
enum AgentGlyph {
    static func icon(tone: ActivityTone, motion: ActivityMotion, background: Bool = false) -> ActivityIcon {
        let symbol: String
        switch (tone, motion) {
        case (.attention, .heartbeat): symbol = "hand.raised"
        case (.attention, _): symbol = background ? "exclamationmark.circle" : "arrow.triangle.2.circlepath"
        case (.danger, _): symbol = "exclamationmark.triangle"
        case (.quiet, _): symbol = "circle"
        case (.live, .sweep): symbol = "arrow.triangle.2.circlepath"
        case (.live, _): symbol = background ? "timer" : "circle.fill"
        }
        return ActivityIcon(symbol: symbol, glyph: "●", tone: tone, motion: motion)
    }

    static func spoken(tone: ActivityTone, motion: ActivityMotion, background: Bool) -> String {
        switch (tone, motion) {
        case (.attention, .heartbeat): return String(localized: "Needs you")
        case (.attention, _): return background ? String(localized: "Stuck") : String(localized: "Waiting on the provider")
        case (.danger, _): return String(localized: "Failed")
        case (.quiet, _): return String(localized: "Idle")
        case (.live, .sweep): return String(localized: "Waiting on the provider")
        case (.live, _):
            return background ? String(localized: "Working in the background") : String(localized: "Working")
        }
    }

    static func icon(for child: AgentChild) -> ActivityIcon {
        switch child.kind {
        case .agent:
            return child.isActive
                ? .openWork : ActivityIcon(symbol: "circle", glyph: "·", tone: .quiet, motion: .still)
        case .background:
            return child.isActive
                ? ActivityKind.inBackground(tasks: 1).icon
                : ActivityKind.stalled(tasks: 1).icon
        }
    }

    static func icon(for outcome: AgentFinish.Outcome) -> ActivityIcon {
        switch outcome {
        case .done: return .finished
        case .failed: return .failed
        case .stopped: return .stopped
        case .unknown:
            return ActivityIcon(symbol: "checkmark.circle", glyph: "✓", tone: .quiet, motion: .still)
        }
    }

    static func spoken(for outcome: AgentFinish.Outcome) -> String {
        switch outcome {
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .stopped: return String(localized: "Stopped")
        case .unknown: return String(localized: "Finished")
        }
    }

    static func icon(for step: AgentOutcome) -> ActivityIcon {
        switch step {
        case .running: return .openWork
        case .done: return ActivityIcon(symbol: "checkmark.circle", glyph: "✓", tone: .quiet, motion: .still)
        case .failed: return .failed
        case .stopped: return .stopped
        }
    }

    static func spoken(for step: AgentOutcome) -> String {
        switch step {
        case .running: return String(localized: "Running")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .stopped: return String(localized: "Stopped")
        }
    }
}
