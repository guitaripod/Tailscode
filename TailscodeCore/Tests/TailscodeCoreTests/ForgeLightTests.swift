import Foundation
import Testing

@testable import TailscodeCore

@Suite("Video button light")
struct ForgeLightTests {
    private func job(_ walk: (inout ForgeJob) -> Void) -> ForgeJob {
        var job = ForgeJob(recipe: ForgeRecipe(prompt: "a cat"))
        walk(&job)
        return job
    }

    @Test("A job reads as one of seven faces, and an ending is lit only until it has been looked at")
    func faces() {
        #expect(ForgeLight.read(job: job { _ in }, seen: false) == .dark)
        #expect(ForgeLight.read(job: job { $0.submitting() }, seen: false) == .waking)
        let waiting = job {
            $0.submitting()
            $0.accepted(promptID: "p", queued: 2)
        }
        #expect(ForgeLight.read(job: waiting, seen: false) == .waiting(ahead: 2))
        let turn = job {
            $0.submitting()
            $0.accepted(promptID: "p", queued: 0)
        }
        #expect(ForgeLight.read(job: turn, seen: false) == .waking, "its turn is the machine loading, not waiting")
        let running = job {
            $0.submitting()
            $0.accepted(promptID: "p", nodes: 28)
            $0.saw(.progressed("p", census: ForgeCensus(finished: 7, total: 28, running: "pass1")))
        }
        #expect(ForgeLight.read(job: running, seen: false) == .rendering(0.25))
        let saving = job {
            $0.submitting()
            $0.accepted(promptID: "p", nodes: 28)
            $0.saw(.finished("p"))
        }
        #expect(ForgeLight.read(job: saving, seen: false) == .saving)
        let landed = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.delivered(ForgeAsset(filename: "a.mp4", subfolder: "video"))
        }
        #expect(ForgeLight.read(job: landed, seen: false) == .landed)
        #expect(ForgeLight.read(job: landed, seen: true) == .dark, "news until it is read")
        let broke = job {
            $0.submitting()
            $0.accepted(promptID: "p")
            $0.failed("out of memory")
        }
        #expect(ForgeLight.read(job: broke, seen: false) == .failed)
        #expect(ForgeLight.read(job: broke, seen: true) == .dark)
        let stopped = job {
            $0.submitting()
            $0.cancelled()
        }
        #expect(ForgeLight.read(job: stopped, seen: false) == .dark, "a stop was never news to the person who pressed it")
    }

    @Test("Each face wears the colour and the motion the rest of the app gives its meaning")
    func vocabulary() {
        #expect(ForgeLight.waking.tone == .quiet)
        #expect(ForgeLight.waking.motion == .sweep(period: ForgeRing.cometPeriod))
        #expect(ForgeLight.waiting(ahead: 1).motion == .still, "waiting its turn is settled")
        #expect(ForgeLight.rendering(0.4).tone == .live)
        #expect(ForgeLight.saving.motion == .working)
        #expect(ForgeLight.landed.motion == .still)
        #expect(ForgeLight.failed.tone == .danger)
        #expect(ForgeLight.failed.motion == .still, "a failure is never animated into looking busy")
        #expect(ForgeLight.dark.motion == .still)
        #expect(ForgeLight.rendering(0.4).isOut && ForgeLight.waking.isOut && ForgeLight.saving.isOut)
        #expect(!ForgeLight.landed.isOut && !ForgeLight.failed.isOut && !ForgeLight.dark.isLit)
    }

    @Test("No stroke ever crosses the top, whatever the time")
    func strokesNeverWrap() {
        let faces: [ForgeLight] = [
            .waking, .waiting(ahead: 3), .rendering(0.01), .rendering(0.5), .rendering(0.97), .saving,
            .landed, .failed,
        ]
        for light in faces {
            for step in 0..<400 {
                let frame = light.frame(at: Double(step) * 0.0371)
                for stroke in frame.strokes {
                    #expect(stroke.start >= 0 && stroke.length > 0, "\(light) at \(step)")
                    #expect(stroke.end <= 1.0000001, "\(light) at \(step): \(stroke)")
                    #expect(stroke.intensity >= 0 && stroke.intensity <= 1)
                }
            }
        }
        #expect(ForgeLight.dark.frame(at: 3).isEmpty)
    }

    @Test("The comet's tail ends at its head and wraps as two pieces")
    func comet() {
        let near = ForgeRing.comet(head: 0.5)
        #expect(near.count == 4)
        #expect(near.allSatisfy { abs($0.end - 0.5) < 1e-9 })
        #expect(near.map(\.intensity) == near.map(\.intensity).sorted(), "the tail fades toward the back")
        let across = ForgeRing.comet(head: 0.05)
        #expect(across.count > 4, "the longest tails cross the top and are cut there")
        #expect(across.contains { $0.start == 0 })
        #expect(across.contains { abs($0.end - 1) < 1e-9 })
    }

    @Test("Progress fills from the top and a render that has begun is never an empty ring")
    func progress() {
        let begun = ForgeLight.rendering(0).frame(at: 0, reduceMotion: true)
        #expect(begun.strokes.first?.length == ForgeRing.leastArc)
        let half = ForgeLight.rendering(0.5).frame(at: 1.1)
        #expect(half.strokes.first?.start == 0)
        #expect(half.strokes.first?.length == 0.5)
        #expect(half.strokes.contains { $0.intensity == 1 && $0.end <= 0.5 + 1e-9 }, "the light stays on what is painted")
        let eased = ForgeLight.rendering(0.5).frame(at: 0, displayed: 0.3)
        #expect(eased.strokes.first?.length == 0.3, "the arc is drawn where it has been eased to")
    }

    @Test("Reduced motion keeps the facts and drops the movement")
    func reducedMotion() {
        let lit = ForgeLight.rendering(0.6)
        let first = lit.frame(at: 0, reduceMotion: true)
        let later = lit.frame(at: 1.3, reduceMotion: true)
        #expect(first == later)
        #expect(first.strokes.count == 1 && first.strokes[0].intensity == 1)
        let wake = ForgeLight.waking
        #expect(wake.frame(at: 0.2, reduceMotion: true) == wake.frame(at: 0.9, reduceMotion: true))
        let saving = ForgeLight.saving
        #expect(saving.frame(at: 0, reduceMotion: true) == saving.frame(at: 1.7, reduceMotion: true))
    }

    @Test("The arc closes on the machine's word smoothly and starts over for a new render")
    func following() {
        let step = ForgeRing.follow(displayed: 0.2, target: 0.6, elapsed: 0.1)
        #expect(step > 0.2 && step < 0.6)
        let later = ForgeRing.follow(displayed: step, target: 0.6, elapsed: 0.1)
        #expect(later > step && later < 0.6)
        #expect(ForgeRing.follow(displayed: 0.2, target: 0.6, elapsed: 30) > 0.599)
        #expect(ForgeRing.follow(displayed: 0.9, target: 0.0, elapsed: 0.016) == 0, "a new render is not a retreat")
        #expect(ForgeRing.follow(displayed: 0.5, target: 0.5, elapsed: 1) == 0.5)
    }

    @Test("The control says in words what the ring says in light")
    func words() {
        #expect(ForgeEntryPoint.accessibilityLabel(light: .dark) == ForgeEntryPoint.title)
        #expect(ForgeEntryPoint.accessibilityLabel(light: .rendering(0.42)).contains("42"))
        #expect(ForgeEntryPoint.accessibilityLabel(light: .waiting(ahead: 2)).contains("2"))
        #expect(ForgeEntryPoint.tooltip(configured: true, light: .dark) == ForgeEntryPoint.tooltip(configured: true))
        #expect(ForgeEntryPoint.tooltip(configured: true, light: .landed) == ForgeLight.landed.spoken)
        let spoken = [
            ForgeLight.waking, .waiting(ahead: 1), .rendering(0.1), .saving, .landed, .failed,
        ].compactMap(\.spoken)
        #expect(Set(spoken).count == 6, "six lit faces, six different sentences")
    }
}
