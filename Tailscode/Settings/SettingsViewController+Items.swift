import CodingAgentKitApple
import TailscodeCore
import UIKit

extension SettingsViewController {
    /// Settings is the iPhone's own shape: a first page of rows that each open a page, and the
    /// pages. A page doubles as a deep-link target, so anything that spots a broken setting can send
    /// the person straight at it: `tailscode://settings/notifications`.
    enum Page: String, CaseIterable {
        case root, connections, tailnet, notifications, chat, appearance, keys, diagnostics, about

        /// The slugs links were written with before Settings had pages: a section that became a
        /// row on the first page opens the first page.
        init?(slug: String) {
            switch slug {
            case "software", "pro", "midgar", "usage", "settings", "": self = .root
            default:
                guard let page = Page(rawValue: slug) else { return nil }
                self = page
            }
        }

        var title: String {
            switch self {
            case .root: return String(localized: "Settings")
            case .connections: return String(localized: "Servers")
            case .tailnet: return "Tailscale"
            case .notifications: return String(localized: "Notifications")
            case .chat: return String(localized: "Chat")
            case .appearance: return String(localized: "Appearance")
            case .keys: return String(localized: "API Keys")
            case .diagnostics: return String(localized: "Diagnostics")
            case .about: return String(localized: "About")
            }
        }

        var tile: SettingsTile {
            switch self {
            case .root: return SettingsTile("gearshape.fill", .gray)
            case .connections: return SettingsTile("server.rack", .blue)
            case .tailnet: return SettingsTile("circle.grid.3x3.fill", .indigo)
            case .notifications: return SettingsTile("bell.badge.fill", .red)
            case .chat: return SettingsTile("bubble.left.and.text.bubble.right.fill", .green)
            case .appearance: return SettingsTile("paintpalette.fill", .cyan)
            case .keys: return SettingsTile("key.fill", .gray)
            case .diagnostics: return SettingsTile("stethoscope", .gray)
            case .about: return SettingsTile("info", .gray)
            }
        }
    }

    /// A group of rows on one page. Each page's groups are its own; `results` is the search, which
    /// gathers what matched from every page under the name of the page it lives on.
    enum Section: Hashable {
        case midgar, alerts, network, experience, accounts, pro, support
        case servers, addServer, demo, testServers
        case tailnetStatus, discovery
        case permission, finished, needsYou, muted, usageAlerts, liveActivities, push, testNotice
        case composer, dictation, agentSteps, answers, resume
        case theme, density, orb
        case keys
        case logs, report
        case version, feedback, legal
        case results(Page)

        var header: String? {
            switch self {
            case .composer: return String(localized: "Composer")
            case .dictation: return DictationReading.settingsTitle
            case .agentSteps: return String(localized: "Agent steps")
            case .muted: return NoticeRulesWords.mutedTitle
            case .answers: return String(localized: "Answers")
            case .usageAlerts: return String(localized: "Usage")
            case .results(let page): return page.title
            default: return nil
            }
        }
    }

    enum Toggle: Hashable {
        case autoExpandThinking, sendOnReturn, promptEnhancement, compactActivity, responseStats
        case linkEmbeds
        case autoResume
        case dictationChatWords
        case notifyApprovals, notifyUsage, notifyRunningLow, serverPush
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
            case .dictationChatWords: return DictationReading.chatWordsTitle
            case .linkEmbeds: return LinkEmbedsSetting.title
            case .notifyApprovals: return NoticeRulesWords.needsYouTitle
            case .notifyUsage: return String(localized: "Usage warnings")
            case .notifyRunningLow: return String(localized: "Running low")
            case .serverPush: return String(localized: "Push from servers")
            case .liveActivities: return String(localized: "Live Activities")
            case .presenceOrb: return String(localized: "Presence orb")
            }
        }

        /// The words search reads beside the title, which the row itself no longer carries: on a
        /// page they are the group's footer.
        var keywords: String {
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
            case .dictationChatWords: return DictationReading.chatWordsFooter
            case .linkEmbeds: return LinkEmbedsSetting.explanation
            case .notifyApprovals: return NoticeRulesWords.needsYouSubtitle
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

        var isOn: Bool {
            switch self {
            case .autoExpandThinking: return AppPreferences.autoExpandThinking
            case .sendOnReturn: return AppPreferences.sendOnReturn
            case .promptEnhancement: return AppPreferences.promptEnhancement
            case .compactActivity: return AppPreferences.compactActivity
            case .responseStats: return ResponseStatsSetting.isEnabled
            case .autoResume: return AutoResumeSetting.isEnabled
            case .dictationChatWords: return DictationPreferences.usesChatWords
            case .linkEmbeds: return LinkEmbedsSetting.isEnabled
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
            case .dictationChatWords: DictationPreferences.usesChatWords = value
            case .linkEmbeds: LinkEmbedsSetting.setEnabled(value)
            case .notifyApprovals:
                var rules = AppPreferences.noticeRules
                rules.needsYou = value
                AppPreferences.noticeRules = rules
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
        case page(Page)
        case midgar
        case connectionAlert
        case software
        case softwareUpdate
        case profile(ConnectionProfile)
        case addConnection
        case discover
        case leaveDemo
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
        case dictationLanguage
        case haptics
        case streamRenderer
        case appearance
        case chatDensity
        case activityStyle
        case noticeFinish
        case noticeMinimum
        case unmuteAll
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
