import CodingAgentKit
import Testing

@testable import TailscodeCore

@Suite("Neural state")
struct NeuralStateTests {
    private func made(_ activity: ActivityKind?, _ outcome: NeuralOutcome? = nil, zone: NeuralZone? = nil)
        -> NeuralState
    {
        NeuralState.make(activity: activity, outcome: outcome, waitingZone: zone)
    }

    @Test("every activity has an answer, and its tone and motion are the activity's own")
    func everyActivity() {
        for kind in ActivityKind.everyState {
            let state = made(kind)
            let icon = kind.icon
            switch icon.tone {
            case .live: #expect(state.tone == .live, "\(kind)")
            case .attention: #expect(state.tone == .attention, "\(kind)")
            case .danger: #expect(state.tone == .danger, "\(kind)")
            case .quiet: #expect(state.tone == .quiet, "\(kind)")
            }
            switch icon.motion {
            case .still: #expect(state.motion == .still, "\(kind)")
            case .breath: #expect(state.motion == .breath, "\(kind)")
            case .heartbeat: #expect(state.motion == .heartbeat, "\(kind)")
            case .sweep: #expect(state.motion == .sweep, "\(kind)")
            }
        }
    }

    @Test("the lit zone is the tool family the header names")
    func zones() {
        #expect(made(.thinking).zone == .think)
        #expect(made(.writing).zone == .say)
        #expect(made(.usingTool(name: "Read", kind: .fileRead)).zone == .sense)
        #expect(made(.usingTool(name: "Grep", kind: .fileSearch)).zone == .sense)
        #expect(made(.usingTool(name: "Edit", kind: .fileEdit)).zone == .act)
        #expect(made(.usingTool(name: "Write", kind: .fileWrite)).zone == .act)
        #expect(made(.usingTool(name: "Bash", kind: .shell)).zone == .shell)
        #expect(made(.usingTool(name: "Todo", kind: .taskTracking)).zone == .think)
        #expect(made(.delegating(active: 2)).zone == .delegate)
        #expect(made(.needsAnswer).zone == .think)
        #expect(made(.needsApproval).zone == .shell)
        #expect(made(.needsApproval, zone: .act).zone == .act)
        #expect(made(.stalled(tasks: 1)).zone == .shell)
        #expect(made(.stalled(tasks: 1), zone: .delegate).zone == .delegate)
    }

    @Test("whole-head states light no zone")
    func wholeHead() {
        let kinds: [ActivityKind] = [
            .working, .inBackground(tasks: 1), .retrying(attempt: 1), .compacting, .queued(2),
            .connecting, .reconnecting, .offline,
        ]
        for kind in kinds { #expect(made(kind).zone == nil, "\(kind)") }
    }

    @Test("effects follow the table")
    func effects() {
        #expect(made(.compacting).effect == .crunch)
        #expect(made(.inBackground(tasks: 2)).effect == .orbit)
        #expect(made(.offline).effect == .dark)
        #expect(made(.queued(1)).effect == .dim(0.35))
        #expect(made(.connecting).effect == .dim(0.4))
        #expect(made(.reconnecting).effect == .dim(0.4))
        #expect(made(.retrying(attempt: 1)).effect == NeuralEffect.none)
        #expect(made(.thinking).effect == NeuralEffect.none)
    }

    @Test("a failed state holds danger on the failing zone")
    func failed() {
        let state = made(.failed)
        #expect(state.tone == .danger && state.motion == .still)
        #expect(state.zone == .shell && state.failure)
        #expect(made(nil, .failed, zone: .act).zone == .act)
        #expect(made(nil, .failed).failure)
    }

    @Test("a settled turn has no tone and wears the identity")
    func settled() {
        let state = made(nil, .settled)
        #expect(state.wearsIdentity && state.motion == .still && state.zone == nil)
        #expect(state.hasFace)
    }

    @Test("stopped, interrupted and answerless have no face")
    func noFace() {
        for outcome in [NeuralOutcome.stopped, .interrupted, .answerless] {
            let state = made(nil, outcome)
            #expect(!state.hasFace && state.motion == .still && state.effect == .dim(0.4))
            #expect(state.tone == .quiet && state.zone == nil)
        }
    }

    @Test("nothing going on is idle and a running turn nobody can see into is live")
    func idleAndRunning() {
        #expect(made(nil) == NeuralState.idle)
        #expect(NeuralState.idle.tone == .quiet && NeuralState.idle.motion == .still)
        let running = made(nil, .running)
        #expect(running.tone == .live && running.motion == .breath && running.zone == nil)
    }

    @Test("an activity outranks the outcome beside it")
    func precedence() {
        #expect(made(.thinking, .settled).zone == .think)
        #expect(made(.failed, .running).failure)
    }

    @Test("animation follows the motion and the two looping effects, and reduced motion stops all")
    func animation() {
        #expect(made(.thinking).isAnimated())
        #expect(made(.compacting).isAnimated())
        #expect(made(.inBackground(tasks: 1)).isAnimated())
        #expect(!made(.failed).isAnimated())
        #expect(!made(.stalled(tasks: 1)).isAnimated())
        #expect(!made(.offline).isAnimated())
        for kind in ActivityKind.everyState {
            #expect(!made(kind).isAnimated(reduceMotion: true), "\(kind)")
        }
    }
}
