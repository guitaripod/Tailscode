import QuartzCore
import TailscodeCore
import UIKit

extension WatchViewController: KeyActionHost {
    var keyContext: KeyContext { .normal }

    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .toggleAgents, .leaveInsert:
            close()
            return true
        default:
            return false
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        wake()
        guard let key = presses.first?.key else {
            super.pressesBegan(presses, with: event)
            return
        }
        let command = key.modifierFlags.contains(.command)
        let letters = key.charactersIgnoringModifiers.lowercased()
        if key.keyCode == .keyboardEscape || (command && letters == "w") {
            close()
            return
        }
        if key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty {
            if let digit = Int(letters), (1...6).contains(digit) {
                let tiles = stage.wall.tiles
                if digit <= tiles.count { presentPeek(tile: tiles[digit - 1].id) }
                return
            }
            if letters == "d" {
                toggleDim()
                return
            }
            if letters == "s" {
                presentStyle()
                return
            }
        }
        if handleKeyPresses(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    func observeEnvironment() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(environmentChanged), name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        center.addObserver(
            self, selector: #selector(environmentChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(motionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(environmentChanged), name: UIDevice.batteryStateDidChangeNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(environmentChanged), name: UIDevice.batteryLevelDidChangeNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(styleChanged), name: WatchStyleStore.didChange, object: nil)
        center.addObserver(
            self, selector: #selector(themeChanged), name: ThemeSelection.didChange, object: nil)
    }

    private func ownsScene(_ note: Notification) -> Bool {
        guard let scene = note.object as? UIScene else { return true }
        return scene === viewIfLoaded?.window?.windowScene
    }

    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard ownsScene(note), !gateInFlight else { return }
        suspend()
    }

    @objc private func sceneDidEnterBackground(_ note: Notification) {
        guard ownsScene(note) else { return }
        suspend()
    }

    @objc private func sceneDidActivate(_ note: Notification) {
        guard ownsScene(note), viewIfLoaded?.window != nil else { return }
        resume()
        becomeFirstResponder()
    }

    @objc private func environmentChanged() {
        updateAwake()
        updateCadence()
    }

    @objc private func motionChanged() {
        stage.animated = !UIAccessibility.isReduceMotionEnabled
        refresh(.style)
    }

    @objc private func styleChanged() {
        style = WatchStyleStore.current
        stage.apply(style: style, now: Date())
        lastApplied = nil
        refresh(.style)
    }

    @objc private func themeChanged() {
        stage.refreshPalette(now: Date())
        view.backgroundColor = stage.palette.deep.color()
        lastApplied = nil
        refresh(.style)
    }
}
