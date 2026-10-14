import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
  @Suite("Type scale")
  struct TypeScaleTests {
    private func fresh() { TypeScaleStore.forgetAllForTesting() }

    @Test("A size snaps to five percent and stays inside the range")
    func snapsAndClamps() {
      #expect(TypeScale.snapped(1.07) == 1.05)
      #expect(TypeScale.snapped(1.08) == 1.1)
      #expect(TypeScale.snapped(0.1) == TypeScale.lowest)
      #expect(TypeScale.snapped(9) == TypeScale.highest)
      #expect(TypeScale.snapped(.nan) == TypeScale.standard)
    }

    @Test("A step is pinned at both ends, never wrapped")
    func stepsPin() {
      let top = TypeScale([.answer: TypeScale.highest]).stepping(.answer, by: 3)
      #expect(top[.answer] == TypeScale.highest)
      let bottom = TypeScale([.mono: TypeScale.lowest]).stepping(.mono, by: -3)
      #expect(bottom[.mono] == TypeScale.lowest)
      #expect(TypeScale().stepping(.chrome, by: 2).percent(.chrome) == 110)
    }

    @Test("Two sets that say the same thing are equal however they were reached")
    func equalityIgnoresHowItWasReached() {
      #expect(TypeScale([.answer: 1.0]) == TypeScale())
      #expect(TypeScale().setting(.mono, to: 1.2).setting(.mono, to: 1.0) == TypeScale())
      #expect(TypeScale().isStandard)
      #expect(!TypeScale().setting(.mono, to: 1.2).isStandard)
    }

    @Test("A preset is exactly its sizes, and a hand-made set is custom")
    func presetsAreRecognised() {
      for preset in TypePreset.allCases {
        #expect(TypeScale().applying(preset).preset == preset)
      }
      #expect(TypeScale().applying(.reading)[.answer] == 1.3)
      #expect(TypeScale().applying(.reading)[.prompt] == 1.3)
      #expect(TypeScale().applying(.reading)[.chrome] == 1.0)
      #expect(TypeScale().applying(.code)[.terminal] == 1.2)
      #expect(TypeScale().setting(.answer, to: 1.15).preset == nil)
    }

    @Test("Every preset says something different, and the default is the only standard one")
    func presetsAreDistinct() {
      #expect(Set(TypePreset.allCases.map(\.scale.percentages)).count == TypePreset.allCases.count)
      #expect(TypePreset.allCases.filter { $0.scale.isStandard } == [.standard])
    }

    @Test("Every role is set in an area, and what you type is not what the agent writes")
    func rolesMapToAreas() {
      #expect(TypeArea(role: .prompt) == .prompt)
      #expect(TypeArea(role: .composer) == .prompt)
      #expect(TypeArea(role: .promptGlyph) == .prompt)
      #expect(TypeArea(role: .answer) == .answer)
      #expect(TypeArea(role: .thought) == .answer)
      #expect(TypeArea(role: .code) == .mono)
      #expect(TypeArea(role: .toolOutput) == .mono)
      #expect(TypeArea(role: .rowTitle) == .chrome)
      for role in TypeRole.allCases {
        let area = TypeArea(role: role)
        switch Typography.spec(role).axis {
        case .chrome: #expect(area == .chrome)
        case .mono: #expect(area == .mono)
        case .prose: #expect(area == .prompt || area == .answer)
        }
      }
    }

    @Test("The agent's words keep the key the desktops already wrote for the transcript's prose")
    func answerKeepsTheOldKey() {
      #expect(TypeArea.answer.defaultsKey == "tailscode.scale.prose")
      #expect(TypeArea.prompt.defaultsKey == "tailscode.scale.prompt")
      #expect(Set(TypeArea.allCases.map(\.defaultsKey)).count == TypeArea.allCases.count)
    }

    @Test("Sizes persist under the keys Linux already writes, and a normal size leaves nothing behind")
    func storeRoundTrips() {
      fresh()
      TypeScaleStore.set(.answer, to: 1.25)
      #expect(UserDefaults.standard.double(forKey: "tailscode.scale.prose") == 1.25)
      TypeScaleStore.forget()
      #expect(TypeScaleStore.current()[.answer] == 1.25)
      TypeScaleStore.set(.answer, to: 1.0)
      #expect(UserDefaults.standard.object(forKey: "tailscode.scale.prose") == nil)
      fresh()
    }

    @Test("A write that changes nothing says nothing")
    func quietWhenNothingMoved() {
      fresh()
      let posted = NotificationTally()
      let token = NotificationCenter.default.addObserver(
        forName: TypeScaleStore.didChange, object: nil, queue: nil
      ) { _ in posted.bump() }
      TypeScaleStore.set(.mono, to: 1.0)
      #expect(posted.count == 0)
      TypeScaleStore.set(.mono, to: 1.2)
      TypeScaleStore.set(.mono, to: 1.2)
      #expect(posted.count == 1)
      NotificationCenter.default.removeObserver(token)
      fresh()
    }
  }
}

extension TypeScale {
  fileprivate var percentages: [Int] { TypeArea.allCases.map { percent($0) } }
}

private final class NotificationTally: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func bump() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}
