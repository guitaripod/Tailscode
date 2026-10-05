import Darwin
import Foundation
import TailscodeCore

/// What the Mac says about memory, heat and power, as the governor's sample reads it.
struct PressureReading: Sendable, Equatable {
    var host: HostPressure
    /// The app's footprint as a share of `min(8 GiB, 0.15 × physical)`.
    var ownMemory: Double?
    var footprintBytes: UInt64?
    var thermal: ThermalState
    var lowPower: Bool
}

/// The machine's memory pressure, this app's own footprint, and the heat and power state.
///
/// The kernel's memory-pressure source says when the whole Mac is short (`.warning` strained,
/// `.critical` critical, `.normal` back to nominal) and only on a change, so the last word is
/// kept. The app's own share is `phys_footprint` — what Activity Monitor calls Memory, the number
/// jetsam judges — against the limit Core sets for Apple platforms. Thermal state and Low Power Mode
/// are read when sampled. None of it needs an entitlement, so the store build reads the same.
final class MemoryPressure: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var latest: HostPressure = .nominal
    private var injected: HostPressure?
    private let onChange: @Sendable (HostPressure) -> Void

    static let limitBytes = OwnMemory.appleHigh(physicalBytes: ProcessInfo.processInfo.physicalMemory)

    /// - Parameter onChange: called on a utility queue whenever the host's pressure word changes.
    init(onChange: @escaping @Sendable (HostPressure) -> Void = { _ in }) {
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        let made = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        made.setEventHandler { [weak self] in
            self?.heard(Self.pressure(for: made.data))
        }
        source = made
        made.resume()
    }

    func stop() {
        lock.lock()
        let held = source
        source = nil
        lock.unlock()
        held?.cancel()
    }

    /// Replaces what the kernel says, for the drive hook; nil hands the word back to the kernel.
    func inject(_ pressure: HostPressure?) {
        lock.lock()
        let before = injected ?? latest
        injected = pressure
        let after = injected ?? latest
        lock.unlock()
        if before != after { onChange(after) }
    }

    var host: HostPressure {
        lock.lock()
        defer { lock.unlock() }
        return injected ?? latest
    }

    func reading() -> PressureReading {
        let footprint = Self.footprintBytes()
        let info = ProcessInfo.processInfo
        return PressureReading(
            host: host,
            ownMemory: Self.ownShare(footprint: footprint, limit: Self.limitBytes),
            footprintBytes: footprint,
            thermal: Self.thermal(info.thermalState),
            lowPower: info.isLowPowerModeEnabled)
    }

    private func heard(_ pressure: HostPressure) {
        lock.lock()
        let before = injected ?? latest
        latest = pressure
        let after = injected ?? latest
        lock.unlock()
        if before != after { onChange(after) }
    }

    /// The kernel's event as the governor's word. A set carrying several flags is read by its
    /// worst, and an event with none of them is no news.
    static func pressure(for event: DispatchSource.MemoryPressureEvent) -> HostPressure {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .strained }
        return .nominal
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    static func ownShare(footprint: UInt64?, limit: UInt64) -> Double? {
        OwnMemory.ratio(current: footprint, high: limit)
    }

    /// `task_vm_info.phys_footprint`: the memory the kernel charges this process with.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}
