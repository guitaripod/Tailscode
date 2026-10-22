import CodingAgentKit
import CodingAgentKitApple
import Foundation

/// Where the person goes when first run, or adding another machine, ends with a live server: into
/// a conversation rather than back to an empty room. The plan is one answer for both desktops, the
/// machine to start on and the line that says which machine just connected, so the window that
/// closes and the pane that opens never disagree about what happened.
public struct FirstRunLanding: Sendable, Equatable {
    public let profileID: String
    public let toast: String

    public static func make(profile: ConnectionProfile) -> FirstRunLanding {
        FirstRunLanding(profileID: profile.id, toast: FirstRunReading.connectedToast(profile.name))
    }

    /// The question the pane asks on arrival: that machine's own, with its recent chats and the new
    /// chat row first, never "which server" for a person who just answered that.
    public func chooser(servers: [PaneChooserServer], entries: [SessionEntry]) -> PaneChooser {
        PaneChooser(servers: servers, entries: entries, startingOn: profileID)
    }
}
