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
      let top = TypeScale([.prose: TypeScale.highest]).stepping(.prose, by: 3)
      #expect(top[.prose] == TypeScale.highest)
      let bottom = TypeScale([.mono: TypeScale.lowest]).stepping(.mono, by: -3)
      #expect(bottom[.mono] == TypeScale.lowest)
      #expect(TypeScale().stepping(.chrome, by: 2).percent(.chrome) == 110)
    }

    @Test("Two sets that say the same thing are equal however they were reached")
    func equalityIgnoresHowItWasReached() {
      #expect(TypeScale([.prose: 1.0]) == TypeScale())
      #expect(TypeScale().setting(.mono, to: 1.2).setting(.mono, to: 1.0) == TypeScale())
      #expect(TypeScale().isStandard)
      #expect(!TypeScale().setting(.mono, to: 1.2).isStandard)
    }

    @Test("A preset is exactly its sizes, and a hand-made set is custom")
    func presetsAreRecognised() {
      for preset in TypePreset.allCases {
        #expect(TypeScale().applying(preset).preset == preset)
      }
      #expect(TypeScale().applying(.reading)[.prose] == 1.3)
      #expect(TypeScale().applying(.reading)[.chrome] == 1.0)
      #expect(TypeScale().applying(.code)[.terminal] == 1.2)
      #expect(TypeScale().setting(.prose, to: 1.15).preset == nil)
    }

    @Test("Every preset says something different, and the default is the only standard one")
    func presetsAreDistinct() {
      #expect(Set(TypePreset.allCases.map(\.scale.percentages)).count == TypePreset.allCases.count)
      #expect(TypePreset.allCases.filter { $0.scale.isStandard } == [.standard])
    }

    @Test("The three axes of the ramp are three areas")
    func axesMapToAreas() {
      #expect(TypeArea(axis: .chrome) == .chrome)
      #expect(TypeArea(axis: .prose) == .prose)
      #expect(TypeArea(axis: .mono) == .mono)
    }

    @Test("Sizes persist under the keys Linux already writes, and a normal size leaves nothing behind")
    func storeRoundTrips() {
      fresh()
      TypeScaleStore.set(.prose, to: 1.25)
      #expect(UserDefaults.standard.double(forKey: "tailscode.scale.prose") == 1.25)
      TypeScaleStore.forget()
      #expect(TypeScaleStore.current()[.prose] == 1.25)
      TypeScaleStore.set(.prose, to: 1.0)
      #expect(UserDefaults.standard.object(forKey: "tailscode.scale.prose") == nil)
      fresh()
    }

    @Test("A write that changes nothing says nothing")
    func quietWhenNothingMoved() {
      fresh()
      var posted = 0
      let token = NotificationCenter.default.addObserver(
        forName: TypeScaleStore.didChange, object: nil, queue: nil
      ) { _ in posted += 1 }
      TypeScaleStore.set(.mono, to: 1.0)
      #expect(posted == 0)
      TypeScaleStore.set(.mono, to: 1.2)
      TypeScaleStore.set(.mono, to: 1.2)
      #expect(posted == 1)
      NotificationCenter.default.removeObserver(token)
      fresh()
    }
  }
}

extension TypeScale {
  fileprivate var percentages: [Int] { TypeArea.allCases.map { percent($0) } }
}
