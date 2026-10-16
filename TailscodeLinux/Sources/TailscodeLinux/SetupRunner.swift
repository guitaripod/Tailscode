import CodingAgentKit
import Foundation
import TailscodeCore

/// The one `SetupDesk` this process holds, made once with the secrets the rest of this client keeps
/// its passwords in. The desk is an actor that never touches the main queue, so a GTK surface may
/// hold it directly; what a surface adds is only the hop back to the main loop before it draws.
final class SetupRunner: @unchecked Sendable {
    static let shared = SetupRunner(desk: SetupDesk(secrets: FileSecretStore()))

    let desk: SetupDesk

    init(desk: SetupDesk) { self.desk = desk }

    /// Where the gateway for a conversation's server is, as the call finds it.
    func voiceTarget(for entry: SessionEntry) -> SetupTarget? {
        VoiceCallRunner.shared.endpoint(for: entry).map(SetupTarget.voice)
    }
}
