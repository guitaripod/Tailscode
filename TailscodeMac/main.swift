import AppKit

/// `--selftest` never touches AppKit. A Mac reached over ssh has no window server, and
/// `NSApplicationMain` blocks before it ever reaches the delegate there — so the headless path
/// runs on the main queue directly and the app is only started when there is a screen to start it
/// on.
if SelfTest.isRequested {
    Task { await SelfTest.run() }
    dispatchMain()
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
