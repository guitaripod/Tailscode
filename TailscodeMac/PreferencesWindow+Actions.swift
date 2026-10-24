import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UserNotifications

extension PreferencesWindow {
    /// The flight recorder's last quarter hour, decoded, on the pasteboard for a bug report. The
    /// ring holds counts and durations only, so there is nothing in it to redact.
    @objc func copyDiagnostics() {
        Seatbelts.shared.writer?.drain()
        let text = FlightFormatter.format(FlightRing.read(url: FlightRing.defaultURL()), minutes: 15)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func presenceOrbChanged(_ sender: NSButton) {
        PresenceOrbSetting.setEnabled(sender.state == .on)
    }

    @objc func manageServers() { actions.manageServers() }

    @objc func editTailnetToken() {
        guard let window else { return }
        TailnetTokenSheet.present(on: window) { [weak self] in
            DispatchQueue.main.async { self?.install(selecting: nil) }
        }
    }

    @objc func openUpdates() { actions.openUpdates() }

    @objc func openPro() { actions.openPro() }

    @objc func showCheatsheet() { actions.showCheatsheet() }

    @objc func sidebarShownChanged(_ sender: NSButton) {
        actions.setSidebarShown(sender.state == .on)
    }

    @objc func terminalShownChanged(_ sender: NSButton) {
        actions.setTerminalShown(sender.state == .on)
    }

    /// Whether the system will let a notice be raised at all, said where the switches that ask for
    /// notices are: three switches that all read "on" over a permission that is off look like a
    /// fault in the app rather than a decision in System Settings.
    func renderNotificationPermission() {
        Task { [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings()
                .authorizationStatus
            let words: String
            switch status {
            case .authorized, .provisional, .ephemeral:
                words = Localized.text("Allowed — banners and sounds are on")
            case .denied:
                words = Localized.text(
                    "Turned off in System Settings — nothing can be raised until it is on")
            default:
                words = Localized.text("Not asked yet — the Test button below asks")
            }
            self?.permissionState.stringValue = words
        }
    }

    @objc func openNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func revealLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([FlightRing.defaultURL()])
    }

    func renderCacheState() {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(ImageDisk.bytesUsed()), countStyle: .file)
        cacheState.stringValue = Localized.text("%@ kept so chats open faster", size)
        cacheButton.isEnabled = ImageDisk.bytesUsed() > 0
    }

    @objc func clearPictureCache() {
        ImageDisk.clear()
        renderCacheState()
    }

    @objc func leaveDemo() {
        ServerDirectory.shared.leaveDemoMode()
        onTranscriptChanged()
        window?.close()
    }

    @objc func sendOnReturnChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "tailscode.sendOnReturn")
    }

    @objc func vimChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "tailscode.vimComposer")
        onComposerChanged()
    }

    @objc func linesChanged(_ sender: NSStepper) {
        defaults.set(sender.integerValue, forKey: "tailscode.composerLines")
        linesLabel.stringValue = "\(sender.integerValue)"
        onComposerChanged()
    }

    @objc func compactChanged(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "tailscode.compactTools")
        onTranscriptChanged()
    }

    @objc func responseStatsChanged(_ sender: NSButton) {
        ResponseStatsSetting.setEnabled(sender.state == .on)
        onTranscriptChanged()
    }

    @objc func linkEmbedsChanged(_ sender: NSButton) {
        LinkEmbedsSetting.setEnabled(sender.state == .on)
        onTranscriptChanged()
    }

    @objc func autoResumeChanged(_ sender: NSButton) {
        AutoResumeSetting.setEnabled(sender.state == .on)
    }

    @objc func windowChanged(_ sender: NSStepper) {
        defaults.set(sender.integerValue, forKey: "tailscode.transcriptWindow")
        windowLabel.stringValue = "\(sender.integerValue)"
        onTranscriptChanged()
    }

    @objc func hapticsEnabledChanged(_ sender: NSButton) {
        MacHaptics.setEnabled(sender.state == .on)
        if sender.state == .on { MacHaptics.shared.play(.tap, strength: MacHaptics.strength) }
    }

    /// The setting is chosen by feel: every step-width stop the slider passes plays the send cue
    /// at the strength under the pointer, so silence, a single tick and the full recipe are felt
    /// as they are crossed rather than read about afterwards.
    @objc func hapticStrengthChanged(_ sender: NSSlider) {
        MacHaptics.setStrength(sender.doubleValue)
        hapticLabel.stringValue = HapticStrength.label(sender.doubleValue)
        let stop = Int((sender.doubleValue / HapticStrength.step).rounded())
        guard stop != hapticStop else { return }
        hapticStop = stop
        MacHaptics.shared.play(.send, strength: sender.doubleValue)
    }

    @objc func notifyTurnsChanged(_ sender: NSButton) {
        MacNotifier.setNotifyTurnComplete(sender.state == .on)
    }

    @objc func notifyNeedsChanged(_ sender: NSButton) {
        MacNotifier.setNotifyNeedsYou(sender.state == .on)
    }

    @objc func notifyRunningLowChanged(_ sender: NSButton) {
        MacNotifier.setNotifyRunningLow(sender.state == .on)
    }

    @objc func sendTestNotification() {
        MacNotifier.shared.sendTest()
    }

    /// The file is revealed rather than opened where the app is sandboxed: handing a path inside
    /// this app's own container to another program is a door the container does not have, and a
    /// button that quietly opens nothing is worse than one that shows where the file is.
    @objc func editShortcuts() {
        ShortcutSet.ensureConfigFile()
        #if TAILSCODE_MAS
            NSWorkspace.shared.activateFileViewerSelecting([ShortcutSet.configURL])
        #else
            NSWorkspace.shared.open(ShortcutSet.configURL)
        #endif
    }

    @objc func reloadShortcuts() {
        onReloadShortcuts()
    }
}
