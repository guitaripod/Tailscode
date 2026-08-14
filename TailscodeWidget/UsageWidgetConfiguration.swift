import AppIntents
import Foundation
import TailscodeCore

/// A provider the account actually meters, offered by name in the widget's own editor.
///
/// The list is read from the shared snapshot rather than hard-coded, because the providers a person
/// has are the providers their servers answered with — a fixed enum silently drops the next one
/// (which is exactly how a prepaid DeepSeek balance ended up unpickable) and offers three that may
/// not exist on this account.
struct QuotaProviderEntity: AppEntity, Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Provider"))

    var displayRepresentation: DisplayRepresentation {
        subtitle.isEmpty
            ? DisplayRepresentation(title: "\(name)")
            : DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    static let defaultQuery = QuotaProviderQuery()

    static func all() -> [QuotaProviderEntity] {
        let entry = UsageWidgetStore.read() ?? UsageWidgetStore.previewEntry()
        var seen: Set<String> = []
        return entry.providers.compactMap { provider in
            let id = WidgetGlance.key(for: provider.providerName)
            guard seen.insert(id).inserted else { return nil }
            return QuotaProviderEntity(
                id: id, name: ProviderBrand.short(provider.providerName),
                subtitle: provider.subtitle)
        }
    }
}

struct QuotaProviderQuery: EntityQuery {
    func entities(for identifiers: [QuotaProviderEntity.ID]) async throws -> [QuotaProviderEntity] {
        let wanted = Set(identifiers)
        let known = QuotaProviderEntity.all()
        /// A provider that has stopped answering is still the one somebody picked, so it survives
        /// the editor rather than being silently unpicked the first time a server is offline.
        let missing = wanted.subtracting(known.map(\.id)).map {
            QuotaProviderEntity(id: $0, name: ProviderBrand.short($0), subtitle: "")
        }
        return known.filter { wanted.contains($0.id) } + missing
    }

    func suggestedEntities() async throws -> [QuotaProviderEntity] {
        QuotaProviderEntity.all()
    }
}

enum WidgetGroupingChoice: String, AppEnum {
    case automatic
    case hottest
    case byProvider

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Rows"))
    static let caseDisplayRepresentations: [WidgetGroupingChoice: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(
            title: "Automatic", subtitle: "Windows when one provider, a row each when several"),
        .hottest: DisplayRepresentation(
            title: "Tightest windows", subtitle: "Every window in the account, fullest first"),
        .byProvider: DisplayRepresentation(
            title: "One per provider", subtitle: "Each provider's tightest window"),
    ]

    var grouping: WidgetGrouping {
        switch self {
        case .automatic: return .automatic
        case .hottest: return .hottest
        case .byProvider: return .byProvider
        }
    }
}

enum WidgetDetailChoice: String, AppEnum {
    case automatic
    case compact
    case detailed

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Detail"))
    static let caseDisplayRepresentations: [WidgetDetailChoice: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(
            title: "Automatic", subtitle: "As much as the size can hold"),
        .compact: DisplayRepresentation(
            title: "Compact", subtitle: "Numbers only — more windows on screen"),
        .detailed: DisplayRepresentation(
            title: "Detailed", subtitle: "Money and resets under every window"),
    ]

    var detail: WidgetDetail {
        switch self {
        case .automatic: return .automatic
        case .compact: return .compact
        case .detailed: return .detailed
        }
    }
}

/// Where a widget's colour comes from. A widget is on somebody's Home Screen beside their other
/// widgets, so which of the three is right is theirs to say rather than the app's.
enum WidgetAccentChoice: String, AppEnum {
    case theme
    case provider
    case monochrome

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Colour"))
    static let caseDisplayRepresentations: [WidgetAccentChoice: DisplayRepresentation] = [
        .theme: DisplayRepresentation(
            title: "App theme", subtitle: "The palette Tailscode is wearing"),
        .provider: DisplayRepresentation(
            title: "Provider", subtitle: "Each agent's own brand colour"),
        .monochrome: DisplayRepresentation(
            title: "Monochrome", subtitle: "Ink only, whatever the wallpaper"),
    ]
}

struct UsageWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription(
        "Live agent spend and rate-limit quotas across your coding servers.")

    @Parameter(
        title: "Providers",
        description: "Leave empty for every provider your servers report.")
    var providers: [QuotaProviderEntity]?

    @Parameter(title: "Rows", default: .automatic)
    var grouping: WidgetGroupingChoice

    @Parameter(title: "Detail", default: .automatic)
    var detail: WidgetDetailChoice

    @Parameter(title: "Colour", default: .theme)
    var accent: WidgetAccentChoice

    /// Whether the widget shows the reset clock on the window that decides the next send.
    @Parameter(title: "Show reset countdown", default: true)
    var showsReset: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$providers) as \(\.$grouping)") {
            \.$detail
            \.$accent
            \.$showsReset
        }
    }

    /// The picked providers as the reading filters by, or nil for the whole account. An empty pick
    /// is not an empty widget: nobody chooses to see nothing, so it means everything.
    var providerFilter: Set<String>? {
        guard let providers, !providers.isEmpty else { return nil }
        return Set(providers.map(\.id))
    }
}
