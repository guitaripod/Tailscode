#if canImport(AVFoundation) && os(iOS)
    import AVFoundation
    import Foundation

    /// The phone's shared audio session for the length of a call: play and record in voice chat mode,
    /// with Bluetooth hands-free allowed and the loudspeaker as the default when nothing else is
    /// attached. It tells the call when something else takes the audio away and when the route moves.
    final class AppleVoiceAudioSession: @unchecked Sendable {
        private var observers: [NSObjectProtocol] = []

        var isActive: Bool { !observers.isEmpty }

        func activate(
            onInterruptionBegan: @escaping @Sendable () -> Void, onRouteChange: @escaping @Sendable () -> Void
        ) throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) {
                    note in
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began { onInterruptionBegan() }
                },
                center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { _ in
                    onRouteChange()
                },
            ]
        }

        func deactivate() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
#endif
