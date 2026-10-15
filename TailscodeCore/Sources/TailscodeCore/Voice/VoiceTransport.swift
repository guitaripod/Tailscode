import Foundation

public enum VoiceFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

/// The call's socket, with no platform type in sight. `connect` opens a new connection each time it
/// is called and `receive` is the frames of the connection most recently opened, so a call that
/// loses its line dials the same transport again.
public protocol VoiceTransport: Sendable {
    func connect(url: URL, bearer: String?) async throws
    func sendBinary(_ data: Data) async throws
    func sendText(_ text: String) async throws
    func receive() -> AsyncThrowingStream<VoiceFrame, Error>
    func close() async
}
