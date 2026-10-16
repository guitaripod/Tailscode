import AppKit
import TailscodeCore

/// The one road to what a machine can make. Every way in (the video lane's machine pill and its
/// failure card, the picture lane's, the render button's "See what is missing", the servers window's
/// Capabilities row) opens the shared checklist for images and video as a sheet, led by the lane the
/// person came from. The checklist names the machine it checks and offers Change, which opens the
/// renderer picker that already exists as a sheet on the checklist and, once a machine is saved,
/// returns to the checklist for it.
@MainActor
enum MediaSetupGate {
    static func present(
        endpoint: ForgeEndpoint? = ForgeRunner.shared.endpoint, focus: SetupFocus?, on window: NSWindow?,
        onFinish: (() -> Void)? = nil, onChanged: (() -> Void)? = nil
    ) {
        guard let window else { return }
        guard let endpoint else {
            choose(over: window, host: window, focus: focus, onFinish: onFinish, onChanged: onChanged)
            return
        }
        MacSetupGate.present(
            .media(endpoint), focus: focus, on: window, onFinish: onFinish,
            onChange: { sheet in
                choose(over: sheet, host: window, focus: focus, onFinish: onFinish, onChanged: onChanged)
            })
    }

    private static func choose(
        over presenter: NSWindow, host: NSWindow, focus: SetupFocus?, onFinish: (() -> Void)?,
        onChanged: (() -> Void)?
    ) {
        ForgeSetupSheet.present(on: presenter) {
            ForgeRunner.shared.pointAtStoredRenderer()
            onChanged?()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SetupSheet.dismiss {
                        present(
                            endpoint: ForgeRunner.shared.endpoint, focus: focus, on: host, onFinish: onFinish,
                            onChanged: onChanged)
                    }
                }
            }
        }
    }
}
