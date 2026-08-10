import Foundation
import Testing

@testable import TailscodeCore

/// The ramp, proved as data. A type scale is a set of claims — that two voices are told apart, that
/// a number never dances, that no client invents a size — and each is cheap to assert and expensive
/// to notice by eye three clients later.
@Suite struct TypographyTests {
    /// Roles whose text changes while a person is looking at it. Proportional digits there make a
    /// settled fact read as motion.
    private static let changingNumbers: [TypeRole] = [
        .statusLine, .segment, .gauge, .gaugeCaption, .rowStamp, .workflowMeter,
        .metricHero, .metricLarge, .metricValue, .metricDetail,
    ]

    @Test func everyRoleIsSpecifiedAndGrouped() {
        var seen: [TypeGroup: Int] = [:]
        for role in TypeRole.allCases {
            let spec = Typography.spec(role)
            #expect(spec.ratio > 0, "\(role.rawValue) has no size")
            seen[Typography.group(role), default: 0] += 1
        }
        for group in TypeGroup.allCases {
            #expect(seen[group, default: 0] > 0, "\(group.rawValue) names no role")
            #expect(Typography.roles(in: group).count == seen[group], "\(group.rawValue) drifted")
        }
    }

    @Test func theTwoVoicesAreToldApart() {
        let prompt = Typography.spec(.prompt)
        let answer = Typography.spec(.answer)
        #expect(prompt.weight > answer.weight, "the question and its answer are set identically")
        #expect(answer.lineHeight > prompt.lineHeight, "the passage being read has the less air")
    }

    @Test func aNameOutweighsItsDetail() {
        #expect(Typography.spec(.toolName).weight > Typography.spec(.toolDetail).weight)
        #expect(Typography.spec(.rowTitleStrong).weight > Typography.spec(.rowTitle).weight)
        #expect(Typography.spec(.toolName).ratio == Typography.spec(.toolDetail).ratio)
    }

    @Test func numbersThatChangeAreTabular() {
        for role in Self.changingNumbers {
            #expect(Typography.spec(role).figures == .tabular, "\(role.rawValue) dances")
        }
    }

    @Test func theRampStaysInsideItsBand() {
        for role in TypeRole.allCases {
            let spec = Typography.spec(role)
            #expect(spec.ratio >= 0.6 && spec.ratio <= 2.5, "\(role.rawValue) is off the ramp")
            #expect(spec.tracking >= -0.05 && spec.tracking <= 0.12, "\(role.rawValue) is spaced out")
            #expect(spec.lineHeight >= 1 && spec.lineHeight <= 1.2, "\(role.rawValue) leads badly")
        }
    }

    /// `workflowMeter` is the one exemption, and it is not type: its glyphs are a bar, and the
    /// tightening is what closes the gaps between the blocks that draw it.
    @Test func trackingIsSpentOnlyAtTheExtremes() {
        for role in TypeRole.allCases {
            let spec = Typography.spec(role)
            if spec.tracking > 0.02 {
                let spaced = spec.ratio <= 0.8 || (spec.family == .mono && spec.ratio >= 1)
                #expect(spaced, "\(role.rawValue) tracks a size that reads fine untracked")
            }
            if spec.tracking < 0, role != .workflowMeter {
                #expect(spec.ratio >= 0.95, "\(role.rawValue) tightens type that is already small")
            }
        }
    }

    @Test func theCanvasVoiceIsOnlyWhatAPersonTypes() {
        let canvas = TypeRole.allCases.filter { Typography.spec($0).family == .canvas }
        #expect(Set(canvas) == Set([.prompt, .promptGlyph, .composer]))
    }

    @Test func sizeFollowsTheBaseAndThePreference() {
        let spec = Typography.spec(.answer)
        #expect(abs(spec.size(base: 100) - 98) < 0.0001)
        #expect(abs(spec.size(base: 100, scale: 1.5) - 147) < 0.0001)
        #expect(abs(Typography.spec(.headline).tracking(forSize: 20) + 0.2) < 0.0001)
    }

    @Test func everyGroupCarriesItsOwnRegister() {
        for group in TypeGroup.allCases {
            let specs = Typography.roles(in: group).map(Typography.spec)
            let axes = Set(specs.map(\.axis))
            #expect(axes.count <= 2, "\(group.rawValue) is scattered across every size preference")
        }
        #expect(Typography.roles(in: .figures).allSatisfy { Typography.spec($0).axis == .chrome })
        #expect(Typography.roles(in: .navigation).allSatisfy { Typography.spec($0).axis == .chrome })
    }
}
