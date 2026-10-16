import Foundation

/// The one command that puts the voice gateway on a machine, or brings an older one up to date. The
/// script downloads a prebuilt binary and needs no toolchain, and the address is written once so the
/// checklist, the share sheet and the docs can never name different scripts.
public enum VoiceBridgeInstall {
    public static let scriptURL = "https://raw.githubusercontent.com/guitaripod/voice-bridge/master/install.sh"

    public static var installCommand: String { "curl -fsSL \(scriptURL) | bash" }

    public static let installFixID = "voice.install"
}

/// What voice calls ask of a machine, as the app states it before anything is downloaded. The
/// machine's own report wins wherever it carries a number; these are the figures the app quotes when
/// it has not heard from the machine at all.
public enum VoiceRequirements {
    public static let gpuMemoryMB: Int64 = 80 * 1024
    public static let modelBytes: Int64 = 46_868_000_000
    public static let imageBytes: Int64 = 23_622_320_128
    public static let engineMemoryMB: Int64 = 66 * 1024
}
