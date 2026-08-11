import AppKit
import Carbon.HIToolbox
import TailscodeCore

/// The key this app is answered on while another app is in front.
///
/// AppKit has no way to be told about a keystroke that landed somewhere else — a local monitor
/// sees only this process's own events, and a global one is a request to watch every keystroke on
/// the machine, which this feature does not need and should not ask for. Carbon's hot-key
/// registration is the narrow door: one chord, claimed by name, delivered as an event and nothing
/// else. It predates every modern API here and is still the only one that fits.
@MainActor
final class MacSummon {
    static let shared = MacSummon()

    static let didChange = Notification.Name("tailscode.mac.summon.didChange")

    private var hotKey: EventHotKeyRef?
    private var installed = false
    private var summon: (@MainActor () -> Void)?

    private(set) var state: SummonState = .off

    private init() {}

    func start(onSummon: @escaping @MainActor () -> Void) {
        summon = onSummon
        installHandler()
        refresh()
    }

    func refresh() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard SummonSettings.isEnabled else {
            publish(.off)
            return
        }
        let chord = SummonSettings.chord
        if case .refused(let reason) = SummonJudge.judge(chord, on: .apple) {
            publish(.unavailable(reason))
            return
        }
        guard let code = chord.appleKeyCode else {
            publish(.unavailable(Localized.text("This key cannot be claimed system-wide.")))
            return
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x5453_4344), id: 1)
        let status = RegisterEventHotKey(
            code, chord.appleModifierMask, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            publish(.taken(chord, by: nil))
            return
        }
        hotKey = reference
        publish(.bound(chord, reach: .whileRunning))
    }

    fileprivate func fire() {
        NSApp.activate(ignoringOtherApps: true)
        summon?()
    }

    private func publish(_ next: SummonState) {
        state = next
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Installed once for the life of the process. Carbon delivers to an application-wide target,
    /// so a handler per registration would fan one press into as many summons as the chord has
    /// been changed.
    private func installHandler() {
        guard !installed else { return }
        installed = true
        var kind = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                MainActor.assumeIsolated { MacSummon.shared.fire() }
                return noErr
            }, 1, &kind, nil, nil)
    }
}
