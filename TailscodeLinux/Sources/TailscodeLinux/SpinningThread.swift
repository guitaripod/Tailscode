import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// A thread that installs the stack sampler on itself and burns CPU until told to stop, so the
/// self-test has a busy thread to sample that is not the one doing the asking.
final class SpinningThread: @unchecked Sendable {
    private let lock = NSLock()
    private var installed = false
    private var stopping = false
    private var sink = 0.0

    func start() {
        let thread = Thread { [self] in
            _ = tailscode_stack_sampler_install()
            lock.lock()
            installed = true
            lock.unlock()
            while !isStopping { sink += Self.work(20_000) }
        }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    @inline(never)
    private static func work(_ count: Int) -> Double {
        var total = 0.0
        for index in 0..<count { total += Double(index).squareRoot() }
        return total
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    func waitUntilInstalled() -> Bool {
        for _ in 0..<200 {
            lock.lock()
            let ready = installed
            lock.unlock()
            if ready { return true }
            usleep(5_000)
        }
        return false
    }

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }
}
