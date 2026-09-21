import Foundation
import TailscodeCore

/// Whoever owns a prompt helper on this desk: the image studio and the video forge both file
/// the same helper, survey the same machines and offer the same list, so the list is drawn once.
protocol HelperHost: AnyObject, Sendable {
    var helper: ImageGenHelper? { get }
    var helperServers: [ImageGenHelperServer] { get }
    var surveying: Bool { get }
    var surveyedAt: Date? { get }
    func surveyHelpers()
    func setHelper(_ helper: ImageGenHelper?)
    func toggleHelper()
}

/// The helper picker, grouped by machine with the current model marked, the survey's own state
/// at the foot, and the one row that switches the helper off without forgetting it. A menu
/// opened before any survey starts one, so the first opening is never empty for long.
enum HelperMenu {
    static func sections(_ host: HelperHost) -> [Gtk.MenuSection] {
        let current = host.helper
        var sections: [Gtk.MenuSection] = []
        if host.helperServers.isEmpty, !host.surveying { Gtk.onMain { host.surveyHelpers() } }
        for server in host.helperServers {
            let rows = server.models.map { model in
                Gtk.MenuRow(
                    title: model.label, detail: model.detail,
                    on: current?.address == server.address && current?.model == model.id,
                    action: {
                        Gtk.onMain {
                            host.setHelper(ImageGenHelper(address: server.address, model: model))
                        }
                    })
            }
            sections.append(Gtk.MenuSection(heading: server.heading, rows: rows))
        }
        var tail: [Gtk.MenuRow] = []
        if host.surveying {
            tail.append(Gtk.MenuRow(title: ImageGenRewriteWords.lookingTitle, detail: nil))
        } else if host.helperServers.isEmpty {
            tail.append(
                Gtk.MenuRow(
                    title: ImageGenRewriteWords.noneFoundTitle,
                    detail: ImageGenRewriteWords.noneFoundHint))
            tail.append(
                Gtk.MenuRow(
                    title: ImageGenRewriteWords.lookAgainTitle,
                    detail: ImageGenRewriteWords.lookAgainHint,
                    action: { Gtk.onMain { host.surveyHelpers() } }))
        } else {
            tail.append(
                Gtk.MenuRow(
                    title: ImageGenRewriteWords.lookAgainTitle,
                    detail: ImageGenRewriteWords.lookAgainHint,
                    action: { Gtk.onMain { host.surveyHelpers() } }))
        }
        if let current {
            tail.append(
                Gtk.MenuRow(
                    title: current.enabled
                        ? ImageGenRewriteWords.offTitle : ImageGenRewriteWords.onTitle,
                    detail: current.enabled ? ImageGenWords.helperOffHint : current.displayHost,
                    action: { Gtk.onMain { host.toggleHelper() } }))
        }
        sections.append(Gtk.MenuSection(heading: nil, rows: tail))
        return sections
    }

    /// The word the helper link wears: the model, or where the survey stands.
    static func label(_ host: HelperHost) -> String {
        if let helper = host.helper {
            return helper.enabled ? helper.name : "\(helper.name) · \(ImageGenWords.offMark)"
        }
        return host.surveying ? ImageGenRewriteWords.lookingTitle : ImageGenRewriteWords.chooseTitle
    }

    static func tooltip(_ host: HelperHost) -> String {
        host.helper.map { "\(ImageGenRewriteWords.chooseHint) · \($0.label ?? $0.model) · \($0.displayHost)" }
            ?? ImageGenRewriteWords.chooseHint
    }
}
