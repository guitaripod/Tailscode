import Foundation
import Testing

@testable import TailscodeCore

@Suite struct ChatMetricsTests {
    private func everyTable() -> [(ChatDensity, ChatInput, ChatMetrics)] {
        ChatDensity.allCases.flatMap { density in
            [ChatInput.touch, .pointer].map { (density, $0, ChatMetrics.metrics(for: density, input: $0)) }
        }
    }

    @Test func compactNumbersAreTheDesigns() {
        let compact = ChatMetrics.metrics(for: .compact, input: .pointer)
        #expect(compact.paragraphGap == 8, "paragraph gap")
        #expect(compact.proseToFurnitureGap == 4, "prose to furniture gap")
        #expect(compact.proseToCodeGap == 6, "prose to code gap")
        #expect(compact.furnitureGap == 2, "furniture gap")
        #expect(compact.pictureStripGap == 6, "picture strip gap")
        #expect(compact.turnGap == 16, "turn gap")
        #expect(compact.imageMaxHeight == 180, "image max height")
        #expect(compact.imageStripGap == 8, "image strip gutter")
        #expect(compact.codeCollapseLines == 14, "code collapse lines")
        #expect(compact.promptBubblePadding == 6, "prompt bubble padding")
        #expect(compact.railPlateWidth == 440, "plate width")
        #expect(compact.railPlateRows == 8, "plate rows")
    }

    @Test func comfortableIsOneRhythmAndALargerTurnBreak() {
        let comfortable = ChatMetrics.metrics(for: .comfortable, input: .pointer)
        #expect(comfortable.imageMaxHeight == 300)
        #expect(comfortable.promptBubblePadding == 8)
        #expect(comfortable.turnGap == 24)
        let rhythm = Set([
            comfortable.paragraphGap, comfortable.proseToFurnitureGap, comfortable.proseToCodeGap,
            comfortable.furnitureGap, comfortable.pictureStripGap,
        ])
        #expect(rhythm == [12])
    }

    @Test func everyCompactValueIsAtMostItsComfortableValue() {
        for input in [ChatInput.touch, .pointer] {
            let compact = ChatMetrics.metrics(for: .compact, input: input)
            let comfortable = ChatMetrics.metrics(for: .comfortable, input: input)
            #expect(compact.paragraphGap <= comfortable.paragraphGap)
            #expect(compact.proseToFurnitureGap <= comfortable.proseToFurnitureGap)
            #expect(compact.proseToCodeGap <= comfortable.proseToCodeGap)
            #expect(compact.furnitureGap <= comfortable.furnitureGap)
            #expect(compact.pictureStripGap <= comfortable.pictureStripGap)
            #expect(compact.turnGap <= comfortable.turnGap)
            #expect(compact.imageMaxHeight <= comfortable.imageMaxHeight)
            #expect(compact.imageStripGap <= comfortable.imageStripGap)
            #expect(compact.promptBubblePadding <= comfortable.promptBubblePadding)
            #expect(compact.codeCollapseLines <= comfortable.codeCollapseLines)
            #expect(compact.activityRowHeight <= comfortable.activityRowHeight)
            #expect(compact.railOpenRowHeight <= comfortable.railOpenRowHeight)
        }
    }

    @Test func pressableRowsKeepTheirFloors() {
        for (density, input, metrics) in everyTable() {
            let activityFloor: Double = input == .touch ? 32 : 18
            let seamFloor: Double = input == .touch ? 32 : 20
            let railFloor: Double = input == .touch ? 32 : 22
            let openFloor: Double = input == .touch ? 44 : 36
            let label = "\(density) \(input)"
            #expect(metrics.activityRowHeight >= activityFloor, "activity row \(label)")
            #expect(metrics.seamRowHeight >= seamFloor, "seam row \(label)")
            #expect(metrics.railRowHeight >= railFloor, "rail row \(label)")
            #expect(metrics.railOpenRowHeight >= openFloor, "opened rail row \(label)")
        }
    }

    @Test func gapIsZeroAboveTheFirstRow() {
        for (_, _, metrics) in everyTable() {
            for next in ChatRowClass.allCases { #expect(metrics.gap(from: nil, to: next) == 0) }
        }
    }

    @Test func gapIsSymmetricForEveryPairThatDoesNotTouchAPrompt() {
        for (density, input, metrics) in everyTable() {
            for a in ChatRowClass.allCases where a != .prompt {
                for b in ChatRowClass.allCases where b != .prompt {
                    #expect(
                        metrics.gap(from: a, to: b) == metrics.gap(from: b, to: a),
                        "\(a) and \(b) at \(density) \(input)")
                }
            }
        }
    }

    @Test func everyCompactGapIsAtMostItsComfortableGap() {
        for input in [ChatInput.touch, .pointer] {
            let compact = ChatMetrics.metrics(for: .compact, input: input)
            let comfortable = ChatMetrics.metrics(for: .comfortable, input: input)
            for a in ChatRowClass.allCases {
                for b in ChatRowClass.allCases {
                    #expect(compact.gap(from: a, to: b) <= comfortable.gap(from: a, to: b), "\(a) to \(b)")
                }
            }
        }
    }

    @Test func compactGapsFollowTheDesign() {
        let m = ChatMetrics.metrics(for: .compact, input: .pointer)
        #expect(m.gap(from: .prose, to: .prose) == 8)
        for flat in [ChatRowClass.furniture, .seam, .rail] {
            #expect(m.gap(from: .prose, to: flat) == 4, "prose to \(flat)")
            #expect(m.gap(from: flat, to: .prose) == 4, "\(flat) to prose")
            #expect(m.gap(from: .code, to: flat) == 6, "code to \(flat)")
            for other in [ChatRowClass.furniture, .seam, .rail] {
                #expect(m.gap(from: flat, to: other) == 2, "\(flat) to \(other)")
            }
        }
        #expect(m.gap(from: .prose, to: .code) == 6)
        #expect(m.gap(from: .code, to: .prose) == 6)
        #expect(m.gap(from: .prose, to: .picture) == 6)
        #expect(m.gap(from: .picture, to: .furniture) == 6)
        #expect(m.gap(from: .picture, to: .picture) == 8)
        #expect(m.gap(from: .prose, to: .prompt) == 16)
        #expect(m.gap(from: .prompt, to: .prose) == 8, "a prompt is the heading of its answer")
        #expect(m.gap(from: .prompt, to: .furniture) == 8)
        #expect(m.gap(from: .furniture, to: .prompt) == 16)
    }

    @Test func comfortableKeepsTodaysRhythmExceptBetweenTurns() {
        let m = ChatMetrics.metrics(for: .comfortable, input: .pointer)
        for a in ChatRowClass.allCases {
            for b in ChatRowClass.allCases {
                let expected: Double =
                    b == .prompt ? 24 : (a == .picture && b == .picture ? 8 : 12)
                #expect(m.gap(from: a, to: b) == expected, "\(a) to \(b)")
            }
        }
    }
}

@Suite(.serialized) struct ChatDensitySettingTests {
    private func preserving(_ body: () -> Void) {
        let key = ChatDensitySetting.key
        let kept = UserDefaults.standard.object(forKey: key)
        defer {
            if let kept { UserDefaults.standard.set(kept, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    @Test func defaultIsCompact() {
        preserving {
            UserDefaults.standard.removeObject(forKey: ChatDensitySetting.key)
            #expect(ChatDensitySetting.current == .compact)
            UserDefaults.standard.set("nonsense", forKey: ChatDensitySetting.key)
            #expect(ChatDensitySetting.current == .compact)
        }
    }

    @Test func setIsReadBackAndAnnounced() {
        preserving {
            nonisolated(unsafe) var heard = 0
            let token = NotificationCenter.default.addObserver(
                forName: ChatDensitySetting.didChange, object: nil, queue: nil
            ) { _ in heard += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            ChatDensitySetting.set(.comfortable)
            #expect(ChatDensitySetting.current == .comfortable)
            ChatDensitySetting.set(.compact)
            #expect(ChatDensitySetting.current == .compact)
            #expect(heard == 2)
        }
    }

    @Test func theLegacyDenseSwitchOnlyEverMeantTighter() {
        #expect(ChatDensitySetting.migrate(legacyDenseRows: true) == .compact)
        #expect(ChatDensitySetting.migrate(legacyDenseRows: false) == .compact)
        #expect(ChatDensitySetting.migrate(legacyDenseRows: nil) == .compact)
    }

    @Test func keyIsTheOneEveryClientShares() {
        #expect(ChatDensitySetting.key == "tailscode.chatDensity")
        #expect(ChatDensity.allCases == [.compact, .comfortable])
        #expect(ChatDensity.compact.rawValue == "compact")
    }
}
