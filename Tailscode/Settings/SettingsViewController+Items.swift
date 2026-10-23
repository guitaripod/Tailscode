import CodingAgentKitApple
import TailscodeCore
import UIKit

extension SettingsViewController {
    /// Sections double as deep-link targets, so anything that spots a broken
    /// setting can send the user straight at it: `tailscode://settings/notifications`.
    enum Section: String, CaseIterable {
        case midgar, connections, software, tailnet, notifications, usage, chat, appearance, pro,
            diagnostics, about

        var title: String {
            switch self {
            case .midgar: return ""
            case .connections: return String(localized: "Connections")
            case .software: return String(localized: "Software")
            case .tailnet: return String(localized: "Tailnet")
            case .notifications: return String(localized: "Notifications")
            case .usage: return String(localized: "Usage")
            case .chat: return String(localized: "Chat")
            case .appearance: return String(localized: "Appearance")
            case .pro: return "Tailscode Pro"
            case .diagnostics: return String(localized: "Diagnostics")
            case .about: return String(localized: "About")
            }
        }
    }

    enum Toggle: Hashable {
        case autoExpandThinking, sendOnReturn, promptEnhancement, compactActivity, responseStats
        case linkEmbeds
        case autoResume
        case notifyTurnComplete, notifyApprovals, notifyUsage, notifyRunningLow, serverPush
        case liveActivities
        case presenceOrb

        var title: String {
            switch self {
            case .autoExpandThinking: return String(localized: "Auto-expand thinking")
            case .sendOnReturn: return String(localized: "Send on return key")
            case .promptEnhancement: return String(localized: "Enhance prompts")
            case .compactActivity: return String(localized: "Compact agent steps")
            case .responseStats: return ResponseStatsSetting.title
            case .autoResume: return AutoResumeSetting.title
            case .linkEmbeds: return LinkEmbedsSetting.title
            case .notifyTurnComplete: return String(localized: "Turn finished")
            case .notifyApprovals: return String(localized: "Approvals and questions")
            case .notifyUsage: return String(localized: "Usage warnings")
            case .notifyRunningLow: return String(localized: "Running low")
            case .serverPush: return String(localized: "Push from servers")
            case .liveActivities: return String(localized: "Live Activities")
            case .presenceOrb: return String(localized: "Presence orb")
            }
        }

        var subtitle: String? {
            switch self {
            case .autoExpandThinking:
                return String(localized: "Show the agent's reasoning without tapping to unfold it")
            case .sendOnReturn:
                return String(localized: "Return sends instead of inserting a newline")
            case .promptEnhancement:
                return String(localized: "Hold Send to refine your draft with the on-device model")
            case .compactActivity:
                return String(
                    localized: "Agent steps collapse to a slim line — tap to unfold the details")
            case .responseStats: return ResponseStatsSetting.explanation
            case .autoResume: return AutoResumeSetting.explanation
            case .linkEmbeds: return LinkEmbedsSetting.explanation
            case .notifyTurnComplete:
                return String(localized: "When an agent this device is watching goes idle")
            case .notifyApprovals:
                return String(localized: "When an agent stops to ask permission or a question")
            case .notifyUsage:
                return String(localized: "Once per window when a plan limit passes 90%")
            case .notifyRunningLow:
                return String(
                    localized:
                        "Tell me when a usage window is on course to run out before it resets. Account-wide windows only; once per window"
                )
            case .serverPush:
                return String(
                    localized:
                        "Keeps this device registered with claude-bridge, which pushes turn alerts and refreshes the usage widget while the app is closed"
                )
            case .liveActivities: return String(localized: "Live turn progress on the Lock Screen")
            case .presenceOrb:
                return String(
                    localized:
                        "Alpha — a GPU-rendered creature over Home that breathes what every conversation is doing; may cost battery"
                )
            }
        }

        var icon: String {
            switch self {
            case .autoExpandThinking: return "brain"
            case .sendOnReturn: return "return"
            case .promptEnhancement: return "sparkles"
            case .compactActivity: return "rectangle.compress.vertical"
            case .responseStats: return "gauge.with.dots.needle.67percent"
            case .autoResume: return ResumeReading.symbol
            case .linkEmbeds: return "globe"
            case .notifyTurnComplete: return "checkmark.bubble"
            case .notifyApprovals: return "hand.raised"
            case .notifyUsage: return "gauge.with.needle"
            case .notifyRunningLow: return "clock"
            case .serverPush: return "antenna.radiowaves.left.and.right"
            case .liveActivities: return "rectangle.inset.filled.badge.record"
            case .presenceOrb: return "circle.hexagongrid.circle"
            }
        }

        var tint: UIColor {
            switch self {
            case .autoExpandThinking: return ThemePalette.color(\.special, system: .systemPurple)
            case .sendOnReturn: return ThemePalette.color(\.info, system: .systemTeal)
            case .promptEnhancement: return Theme.Color.accent
            case .compactActivity: return ThemePalette.color(\.info, system: .systemOrange)
            case .responseStats: return Theme.Color.info
            case .autoResume: return Theme.Color.warning
            case .linkEmbeds: return Theme.Color.accent
            case .notifyTurnComplete: return Theme.Color.success
            case .notifyApprovals: return Theme.Color.warning
            case .notifyUsage: return Theme.Color.info
            case .notifyRunningLow: return Theme.Color.warning
            case .serverPush: return Theme.Color.accent
            case .liveActivities: return Theme.Color.special
            case .presenceOrb: return Theme.Color.special
            }
        }

        var isOn: Bool {
            switch self {
            case .autoExpandThinking: return AppPreferences.autoExpandThinking
            case .sendOnReturn: return AppPreferences.sendOnReturn
            case .promptEnhancement: return AppPreferences.promptEnhancement
            case .compactActivity: return AppPreferences.compactActivity
            case .responseStats: return ResponseStatsSetting.isEnabled
            case .autoResume: return AutoResumeSetting.isEnabled
            case .linkEmbeds: return LinkEmbedsSetting.isEnabled
            case .notifyTurnComplete: return AppPreferences.notifyTurnComplete
            case .notifyApprovals: return AppPreferences.notifyApprovals
            case .notifyUsage: return AppPreferences.notifyUsageWarnings
            case .notifyRunningLow: return AppPreferences.notifyRunningLow
            case .serverPush: return AppPreferences.pushAlertsEnabled
            case .liveActivities: return AppPreferences.liveActivitiesEnabled
            case .presenceOrb: return PresenceOrbSetting.isEnabled
            }
        }

        @MainActor
        func set(_ value: Bool) {
            switch self {
            case .autoExpandThinking: AppPreferences.autoExpandThinking = value
            case .sendOnReturn: AppPreferences.sendOnReturn = value
            case .promptEnhancement: AppPreferences.promptEnhancement = value
            case .compactActivity: AppPreferences.compactActivity = value
            case .responseStats: ResponseStatsSetting.setEnabled(value)
            case .autoResume: AutoResumeSetting.setEnabled(value)
            case .linkEmbeds: LinkEmbedsSetting.setEnabled(value)
            case .notifyTurnComplete: AppPreferences.notifyTurnComplete = value
            case .notifyApprovals: AppPreferences.notifyApprovals = value
            case .notifyUsage: AppPreferences.notifyUsageWarnings = value
            case .notifyRunningLow: AppPreferences.notifyRunningLow = value
            case .serverPush:
                AppPreferences.pushAlertsEnabled = value
                PushRegistrar.applyPreference()
            case .liveActivities:
                AppPreferences.liveActivitiesEnabled = value
                if !value { AppActivityController.shared.withdrawAll() }
            case .presenceOrb: PresenceOrbSetting.setEnabled(value)
            }
        }
    }

    enum Item: Hashable {
        case midgar
        case connectionAlert
        case profile(ConnectionProfile)
        case addConnection
        case discover
        case leaveDemo
        case software
        case tailnetStatus
        case tailnetToken
        case tailnetScan
        case notificationPermission
        case backgroundRefresh
        case toggle(Toggle)
        case pushState(String)
        case testNotification
        case usage
        case ollamaKey
        case deepseekKey
        case keyboardShortcuts
        case haptics
        case streamRenderer
        case appearance
        case chatDensity
        case activityStyle
        case pro
        case viewLogs
        case testAll
        case copyDiagnostics
        case emailDiagnostics
        case version
        case source
        case privacy
        case support
        case licenses
        case rate
        case share
    }
}
