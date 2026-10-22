import Foundation

/// How a turn's thinking and working is drawn in the transcript: as Megatron, the mecha head that
/// holds one turn, or as the lines the transcript used before Megatron existed. The case keeps the
/// raw value `brain` because it is what devices already hold under `tailscode.activityStyle`.
public enum ActivityStyle: String, Sendable, CaseIterable {
    case brain
    case lines

    public var title: String {
        switch self {
        case .brain: return Localized.text("Megatron")
        case .lines: return Localized.text("Lines")
        }
    }

    public var explanation: String {
        switch self {
        case .brain:
            return Localized.text(
                "Everything the agent did before answering is one head: each thought, tool call and note is a node, and the zone doing the work glows.")
        case .lines:
            return Localized.text(
                "Tool calls and thoughts rest as flat lines, one run after another, the way the transcript read before Megatron.")
        }
    }
}

/// The reader's choice of ``ActivityStyle``, device-local like every other thing about how this
/// app looks. Megatron until somebody asks otherwise; Lines stays for a person who prefers it, a
/// machine without the texture format the brain needs, and a tiling budget that has shed it.
public enum ActivityStyleSetting {
    public static let key = "tailscode.activityStyle"
    public static let didChange = Notification.Name("tailscode.activityStyle.didChange")

    public static var current: ActivityStyle {
        UserDefaults.standard.string(forKey: key).flatMap(ActivityStyle.init(rawValue:)) ?? .brain
    }

    public static func set(_ value: ActivityStyle) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var title: String { Localized.text("Activity style") }

    public static var explanation: String {
        Localized.text(
            "How the transcript shows what an agent did before it answered. Megatron draws one head per turn; lines keep the flat rows.")
    }
}
