import Foundation

/// Whether the machine is running on mains power, for "keep the screen on while charging". The
/// answer is read from the kernel's power supplies and kept for a minute: the file reads are tiny,
/// but nothing on the wall should ask the disk twice a second.
final class WatchPower: @unchecked Sendable {
    static let rereadEvery: TimeInterval = 60

    private let reading: () -> Bool
    private var answer: Bool
    private var readAt: Date

    init(now: Date = Date(), reading: @escaping () -> Bool = WatchPower.systemReading) {
        self.reading = reading
        answer = reading()
        readAt = now
    }

    func isOnMains(at now: Date) -> Bool {
        if now.timeIntervalSince(readAt) >= Self.rereadEvery || now < readAt {
            answer = reading()
            readAt = now
        }
        return answer
    }

    /// A machine with a mains supply that is online is plugged in; one whose supplies are its own
    /// battery and a mains that is not online runs on the battery; one with neither is a desktop,
    /// which is always on mains. A mouse's or a controller's battery (`scope` Device) is not the
    /// machine's.
    static func systemReading() -> Bool {
        let root = URL(fileURLWithPath: "/sys/class/power_supply", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var sawMains = false
        var sawBattery = false
        for name in names {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            switch text(directory.appendingPathComponent("type")) {
            case "Mains":
                sawMains = true
                if text(directory.appendingPathComponent("online")) == "1" { return true }
            case "Battery":
                if text(directory.appendingPathComponent("scope")) != "Device" { sawBattery = true }
            default:
                break
            }
        }
        return !(sawMains || sawBattery)
    }

    private static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
