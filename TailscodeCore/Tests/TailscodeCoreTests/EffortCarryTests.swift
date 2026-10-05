import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Effort carry")
struct EffortCarryTests {
    private let claude = ["low", "medium", "high", "xhigh", "max", "ultracode"]

    @Test("A level the model takes is kept as it is")
    func kept() {
        let carry = ModelEffort.carry("high", options: claude)
        #expect(carry.level == "high")
        #expect(!carry.moved)
        #expect(carry.notice(modelName: "Opus") == nil)
    }

    @Test("A level the model lacks moves to the nearest cooler one, never a hotter one")
    func nearestCooler() {
        #expect(ModelEffort.carry("max", options: ["low", "medium", "high"]).level == "high")
        #expect(ModelEffort.carry("xhigh", options: ["low", "high", "max"]).level == "high")
        #expect(ModelEffort.carry("medium", options: ["high", "max"]).level == nil)
        #expect(ModelEffort.carry("low", options: ["medium", "high"]).level == nil)
        #expect(ModelEffort.carry("ultracode", options: ["low", "medium", "high", "xhigh"]).level == "xhigh")
        #expect(ModelEffort.carry("ultracode", options: ["low", "medium", "high", "xhigh", "max"]).level == "max")
        #expect(ModelEffort.carry("ultracode", options: claude).level == "ultracode")
    }

    @Test("The floor under low is cooler than low and so a home for it")
    func floor() {
        #expect(ModelEffort.carry("low", options: ["none", "thinking"]).level == "none")
        #expect(ModelEffort.carry("medium", options: ["minimal", "low", "high"]).level == "low")
    }

    @Test("A model with no levels, or a word nobody can place, hands the level back")
    func handedBack() {
        let none = ModelEffort.carry("high", options: [])
        #expect(none.level == nil && none.moved && !none.takesLevels)
        let custom = ModelEffort.carry("turbo", options: claude)
        #expect(custom.level == nil && custom.moved && custom.takesLevels)
        #expect(ModelEffort.carry("high", options: ["shallow", "deep"]).level == "deep")
        #expect(ModelEffort.carry(nil, options: claude).level == nil)
        #expect(!ModelEffort.carry(nil, options: claude).moved)
    }

    @Test("A move is said in words, before and after")
    func words() {
        let carry = ModelEffort.carry("max", options: ["low", "medium", "high"])
        #expect(carry.notice(modelName: "Sonnet") == "max moved to high. Sonnet has no max.")
        #expect(carry.forecast(modelName: "Sonnet") == "max will carry over as high.")
        let none = ModelEffort.carry("high", options: [])
        #expect(none.notice(modelName: "Qwen") == "high dropped. Qwen takes no effort level.")
        #expect(none.forecast(modelName: "Qwen") == "Qwen takes no effort level.")
        let back = ModelEffort.carry("medium", options: ["high", "max"])
        #expect(back.notice(modelName: "Pro") == "medium handed back to the server. Pro has no cooler level.")
        let power = ModelEffort.carry("ultracode", options: ["low", "high"])
        #expect(power.notice(modelName: "Haiku") == "ultracode moved to high. Haiku has no ultracode.")
        let budget = ModelEffort.carry("4096", options: claude)
        #expect(budget.notice(modelName: "Opus") == "4096 handed back to the server. Opus has no 4096.")
        #expect(budget.forecast(modelName: "Opus") == "4096 will go back to the server.")
        let think = ModelEffort.carry("think", options: claude)
        #expect(think.notice(modelName: "Opus") == "think moved to medium. Opus has no think.")
        let off = ModelEffort.carry("nothink", options: ["low", "high"])
        #expect(off.notice(modelName: "Gemini") == "nothink handed back to the server. Gemini has no cooler level.")
    }

    @Test("A difference of case alone is no move and says nothing")
    func caseAlone() {
        let carry = ModelEffort.carry("High", options: claude)
        #expect(carry.level == "high" && !carry.moved)
        #expect(carry.notice(modelName: "Opus") == nil && carry.forecast(modelName: "Opus") == nil)
        let upper = ModelEffort.carry("low", options: ["Low", "HIGH"])
        #expect(upper.level == "Low" && !upper.moved)
    }

    @Test("A model pick carries the level through the catalog's own variants")
    func throughCatalog() {
        let sonnet = ModelInfo(id: "s", name: "S", providerID: "anthropic", variants: ["low", "medium", "high"])
        let carry = ModelEffort.adoption("max", for: sonnet.selection, models: [sonnet], agentOptions: [])
        #expect(carry.level == "high" && carry.moved)
        #expect(ModelEffort.adopt("max", for: sonnet.selection, models: [sonnet], agentOptions: []) == "high")
    }
}

@Suite("Effort rail")
struct EffortRailTests {
    private let centers = [23.0, 69, 115, 161, 207, 253]

    @Test("The nearest row wins when nothing is held")
    func nearest() {
        #expect(EffortRail.target(current: nil, centers: centers, y: 20) == 0)
        #expect(EffortRail.target(current: nil, centers: centers, y: 120) == 2)
        #expect(EffortRail.target(current: nil, centers: centers, y: 900) == 5)
        #expect(EffortRail.target(current: nil, centers: [], y: 0) == nil)
    }

    @Test("A held rung is kept until the finger is clearly nearer another")
    func hysteresis() {
        #expect(EffortRail.target(current: 2, centers: centers, y: 95) == 2)
        #expect(EffortRail.target(current: 2, centers: centers, y: 90) == 2, "nearer the next row by four points is not enough")
        #expect(EffortRail.target(current: 2, centers: centers, y: 82) == 1)
        #expect(EffortRail.target(current: 2, centers: centers, y: 140) == 2)
        #expect(EffortRail.target(current: 2, centers: centers, y: 150) == 3)
        #expect(EffortRail.target(current: 9, centers: centers, y: 120) == 2, "a stale index is no hold")
    }

    @Test("A tick is one per rung entered")
    func ticks() {
        #expect(EffortRail.ticks(from: 1, to: 2))
        #expect(!EffortRail.ticks(from: 2, to: 2))
        #expect(EffortRail.ticks(from: nil, to: 0))
        #expect(!EffortRail.ticks(from: 1, to: nil))
    }

    @Test("Straying far sideways cancels")
    func cancel() {
        #expect(!EffortRail.cancels(horizontalDistance: 30))
        #expect(EffortRail.cancels(horizontalDistance: 120))
    }
}

@Suite("Effort scrub")
struct EffortScrubTests {
    private let claude = ["low", "medium", "high", "xhigh", "max", "ultracode"]

    @Test("A hand moving along the bars climbs the model's own ladder one level per notch")
    func climbs() {
        var scrub = EffortScrub(level: "low")
        #expect(scrub.move(to: 0, options: claude).isEmpty)
        #expect(scrub.move(to: 1, options: claude) == ["medium"])
        #expect(scrub.move(to: 4, options: claude) == ["high", "xhigh", "max"])
        #expect(scrub.level == "max")
    }

    @Test("Sliding back down walks the same levels in reverse")
    func descends() {
        var scrub = EffortScrub(level: "xhigh")
        #expect(scrub.move(to: -2, options: claude) == ["high", "medium"])
        #expect(scrub.move(to: -3, options: claude) == ["low"])
    }

    @Test("It stops at both ends and a reversal leaves at once, with no dead zone")
    func noDeadZone() {
        let options = ["low", "medium", "high"]
        var scrub = EffortScrub(level: "low")
        #expect(scrub.move(to: 6, options: options) == ["medium", "high"])
        #expect(scrub.level == "high")
        #expect(scrub.move(to: 5, options: options) == ["medium"])
        var floor = EffortScrub(level: "medium")
        #expect(floor.move(to: -5, options: options) == ["low"])
        #expect(floor.move(to: -4, options: options) == ["medium"])
    }

    @Test("The server's own stop is a place a slide starts from and never falls onto")
    func serverStop() {
        var scrub = EffortScrub(level: nil)
        #expect(scrub.move(to: -3, options: claude).isEmpty)
        #expect(scrub.level == nil)
        #expect(scrub.move(to: -2, options: claude) == ["low"])
    }

    @Test("A model with one level, or none, has nowhere to slide")
    func nowhere() {
        var one = EffortScrub(level: "thinking")
        #expect(one.move(to: 3, options: ["thinking"]).isEmpty)
        var none = EffortScrub(level: nil)
        #expect(none.move(to: 3, options: []).isEmpty)
    }

    @Test("A notch is a fixed distance, whole notches only, and a right-to-left layout flips it")
    func distance() {
        #expect(EffortScrub.notches(translation: 23) == 0)
        #expect(EffortScrub.notches(translation: 24) == 1)
        #expect(EffortScrub.notches(translation: -49) == -2)
        #expect(EffortScrub.notches(translation: 48, rightToLeft: true) == -2)
    }
}
