#if DEBUG
import Foundation
import MidgarCore

/// What the app holds, said on a clock so a change to what a chat keeps can be priced on a device.
///
/// `TAILSCODE_MEMORY_WATCH=<seconds>` writes the footprint the system charges the app (the figure
/// it is ended over) to the `performance` log at that pace as `MEMORY` lines, with the highest it
/// has been since launch.
@MainActor
enum MemoryWatch {
    private static var peak = 0

    static func install() {
        guard
            let pace = ProcessInfo.processInfo.environment["TAILSCODE_MEMORY_WATCH"].flatMap(Double.init),
            pace > 0
        else { return }
        Task {
            while !Task.isCancelled {
                report()
                try? await Task.sleep(for: .seconds(pace))
            }
        }
    }

    private static func report() {
        let now = footprintMegabytes()
        peak = max(peak, now)
        MidgarLog.info("MEMORY footprint \(now) MB peak \(peak) MB", category: .performance)
    }

    static func footprintMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
#endif
