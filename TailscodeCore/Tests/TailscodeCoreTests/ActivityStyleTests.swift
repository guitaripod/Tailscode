import Foundation
import Testing

@testable import TailscodeCore

@Suite(.serialized) struct ActivityStyleTests {
    private func preserving(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: ActivityStyleSetting.key)
        defer {
            if let before { defaults.set(before, forKey: ActivityStyleSetting.key) }
            else { defaults.removeObject(forKey: ActivityStyleSetting.key) }
        }
        body()
    }

    @Test func theBrainIsTheDefault() {
        preserving {
            UserDefaults.standard.removeObject(forKey: ActivityStyleSetting.key)
            #expect(ActivityStyleSetting.current == .brain)
        }
    }

    @Test func aChoiceRoundTrips() {
        preserving {
            ActivityStyleSetting.set(.lines)
            #expect(ActivityStyleSetting.current == .lines)
            #expect(UserDefaults.standard.string(forKey: ActivityStyleSetting.key) == "lines")
            ActivityStyleSetting.set(.brain)
            #expect(ActivityStyleSetting.current == .brain)
        }
    }

    @Test func anUnknownStoredValueFallsBackToTheBrain() {
        preserving {
            UserDefaults.standard.set("hologram", forKey: ActivityStyleSetting.key)
            #expect(ActivityStyleSetting.current == .brain)
        }
    }

    @Test func theKeyIsTheOneEveryClientShares() {
        #expect(ActivityStyleSetting.key == "tailscode.activityStyle")
        #expect(ActivityStyle.allCases == [.brain, .lines])
        #expect(ActivityStyle.brain.rawValue == "brain")
        #expect(ActivityStyle.lines.title == "Lines")
        #expect(!ActivityStyle.brain.explanation.isEmpty)
    }

    @Test func settingPostsAChange() async {
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(
            forName: ActivityStyleSetting.didChange, object: nil, queue: nil
        ) { _ in seen.mark() }
        defer { NotificationCenter.default.removeObserver(token) }
        preserving { ActivityStyleSetting.set(.lines) }
        #expect(seen.count >= 1)
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var hits = 0

        func mark() {
            lock.lock()
            hits += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return hits
        }
    }
}

@Suite struct NeuralCapabilityTests {
    @Test func theCapabilityIsInTheRegistry() {
        let found = CapabilityRegistry.all.filter { $0.id == .neuralTrace }
        #expect(found.count == 1)
        #expect(found.first?.area == "transcript")
        #expect(found.first?.title == "Everything an agent did is one brain")
        #expect((found.first?.spec.count ?? 0) > 200)
    }

    @Test func everyCapabilityHasExactlyOneDefinition() {
        for capability in AppCapability.allCases {
            #expect(CapabilityRegistry.all.filter { $0.id == capability }.count == 1, "\(capability)")
        }
    }

    @Test func everyClientManifestAnswersIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifests = [
            "Tailscode/App/Parity.swift", "TailscodeMac/Parity.swift",
            "TailscodeLinux/Sources/TailscodeLinux/Parity.swift",
        ]
        for path in manifests {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            #expect(text.contains("case .neuralTrace:"), "\(path)")
        }
    }
}
