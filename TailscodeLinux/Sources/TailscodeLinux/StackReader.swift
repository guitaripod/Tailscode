import Foundation
import TailscodeCore

/// `tailscode --stacks [count]`: the last captures the watchdog wrote to the log, with the frames
/// of the main thread resolved to functions and lines where `addr2line` can do it.
///
/// A capture is a summary line (why, what the main thread was waiting in, size, the hottest
/// threads, the build) and the stacks sampled after it, innermost frame first, each frame a
/// module-relative offset. The offsets resolve against the binary that wrote them, so a different
/// build than the one the summary names is said first; `TAILSCODE_BINARY` points at the right one.
enum StackReader {
    private static let libraryDirectories = [
        "/usr/lib", "/usr/lib64", "/usr/lib/x86_64-linux-gnu", "/lib64", "/usr/lib/aarch64-linux-gnu",
    ]

    static func printCaptures(count: Int) -> Int32 {
        let log = [AppLog.previous, AppLog.current]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let groups = StackReport.captures(in: log, last: count)
        guard !groups.isEmpty else {
            print("no captures in \(AppLog.current.path)")
            return 1
        }
        let paths = resolvers(for: groups)
        for group in groups {
            printGroup(group, paths: paths)
        }
        return 0
    }

    private static func printGroup(_ group: [String], paths: [String: [UInt64: String]]) {
        guard let summary = group.first else { return }
        print(summary)
        if let build = build(of: summary), build != TailscodeVersion.current {
            print("  written by build \(build); this is \(TailscodeVersion.current), so frames may not resolve")
        }
        for line in group.dropFirst() {
            guard let range = line.range(of: "main: ") else { continue }
            let head = line[..<range.lowerBound].components(separatedBy: StackReport.marker).last ?? ""
            print("  \(head)main:")
            for (index, token) in line[range.upperBound...].split(separator: " ").enumerated() {
                guard let frame = StackReport.parseFrame(token) else {
                    print("    \(token)")
                    continue
                }
                let place = paths[frame.module]?[frame.offset]
                print("    #\(index) \(place.map { "\($0)  " } ?? "")\(token)")
            }
        }
        print("")
    }

    private static func build(of summary: String) -> String? {
        summary.components(separatedBy: " · ").last(where: { $0.hasPrefix("build ") })
            .map { String($0.dropFirst("build ".count)) }
    }

    /// Module name to (offset to "function at file:line"), for every frame in `groups` that a
    /// module on this machine can name.
    private static func resolvers(for groups: [[String]]) -> [String: [UInt64: String]] {
        var wanted: [String: Set<UInt64>] = [:]
        for line in groups.joined() {
            guard let range = line.range(of: "main: ") else { continue }
            for token in line[range.upperBound...].split(separator: " ") {
                if let frame = StackReport.parseFrame(token) { wanted[frame.module, default: []].insert(frame.offset) }
            }
        }
        var resolved: [String: [UInt64: String]] = [:]
        for (module, offsets) in wanted {
            guard let path = binary(named: module) else { continue }
            let ordered = offsets.sorted()
            guard let answers = addr2line(path: path, offsets: ordered) else { continue }
            var places: [UInt64: String] = [:]
            for (offset, answer) in zip(ordered, answers) {
                if let answer { places[offset] = answer }
            }
            resolved[module] = places
        }
        return resolved
    }

    private static func binary(named module: String) -> String? {
        let files = FileManager.default
        let own = ProcessInfo.processInfo.environment["TAILSCODE_BINARY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (try? files.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
        if let own, URL(fileURLWithPath: own).lastPathComponent == module { return own }
        if let own, module == "tailscode" || module == "TailscodeLinux" { return own }
        return libraryDirectories.map { "\($0)/\(module)" }.first { files.fileExists(atPath: $0) }
    }

    /// One `function at file:line` per offset, nil where the tool had nothing to say.
    private static func addr2line(path: String, offsets: [UInt64]) -> [String?]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["addr2line", "-f", "-C", "-e", path] + offsets.map { "0x" + String($0, radix: 16) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= offsets.count * 2 else { return nil }
        return (0..<offsets.count).map { index in
            let function = String(lines[index * 2])
            let place = String(lines[index * 2 + 1])
            guard function != "??" else { return nil }
            return place.hasPrefix("??") ? function : "\(function) at \(place)"
        }
    }
}
