import Foundation
import Testing

@testable import TailscodeCore

/// Home holds every chat a press at a time, lets a band be shut, and never calls a chat unread
/// because its read mark fell off the end of a bounded record.
extension DeviceStores {
  @Suite("Home reach, folds and the bounded read record")
  struct HomeReachTests {

    private func fresh() {
      let defaults = UserDefaults.standard
      for key in [
        SessionSeenStore.seenKey, SessionSeenStore.baselineKey, SessionSeenStore.liftedKey,
        HomeFolds.storageKey,
      ] {
        defaults.removeObject(forKey: key)
      }
      MarkIntentStore.forgetAllForTesting()
      SessionOwners.forgetAllForTesting()
    }

    @Test("The foot adds a page at a time and then offers the way back")
    func reachPages() {
      var reach = HomeReach()
      #expect(reach.foot(hidden: 0) == nil)
      #expect(reach.foot(hidden: 42) == .more(hidden: 42))
      reach.press(.more(hidden: 42))
      #expect(HomeBandLimits.phone.reaching(reach).recent == HomeBandLimits.phone.recent + HomeReach.step)
      #expect(reach.foot(hidden: 22) == .more(hidden: 22))
      reach.press(.more(hidden: 22))
      reach.press(.more(hidden: 2))
      #expect(reach.foot(hidden: 0) == .fewer)
      reach.press(.fewer)
      #expect(reach == HomeReach())
      #expect(HomeBandLimits.phone.reaching(reach) == .phone)
    }

    @Test("A board beside a chat list has no recent band to open")
    func columnStaysShut() {
      var reach = HomeReach()
      reach.press(.more(hidden: 9))
      #expect(HomeBandLimits.column.reaching(reach) == .column)
    }

    @Test("A band is shut and opened again, and what waits on the person never is")
    func folds() {
      fresh()
      #expect(HomeFolds.shut().isEmpty)
      #expect(HomeFolds.toggle(.pinned))
      #expect(HomeFolds.toggle(.recent))
      #expect(HomeFolds.shut() == [.pinned, .recent])
      #expect(!HomeFolds.toggle(.pinned))
      #expect(HomeFolds.shut() == [.recent])
      #expect(!HomeFolds.toggle(.needsYou))
      #expect(HomeFolds.shut() == [.recent])
    }

    @Test("A read chat whose mark fell off the record stays read")
    func trimKeepsReadChatsRead() {
      fresh()
      let installed = Date().timeIntervalSince1970 - 90 * 86_400
      UserDefaults.standard.set(installed, forKey: SessionSeenStore.baselineKey)
      var marks: [String: Double] = [:]
      for index in 0..<SessionSeenStore.capacity + 50 {
        marks["s\(index)"] = installed + 86_400 + Double(index)
      }
      SessionSeenStore.adopt(marks)
      #expect(SessionSeenStore.values().count == SessionSeenStore.capacity)
      #expect(SessionSeenStore.values()["s0"] == nil)
      let unread = SessionSeenStore.unreadEvaluator()
      let lastChange = Date(timeIntervalSince1970: installed + 86_400 - 60)
      #expect(!unread("s0", lastChange))
      #expect(unread("s0", Date()))
    }

    @Test("A record already cut at the old bound is repaired once")
    func liftRepairsAnOldTrim() {
      fresh()
      let installed = Date().timeIntervalSince1970 - 90 * 86_400
      UserDefaults.standard.set(installed, forKey: SessionSeenStore.baselineKey)
      var marks: [String: Double] = [:]
      for index in 0..<300 { marks["s\(index)"] = installed + 30 * 86_400 + Double(index) }
      UserDefaults.standard.set(marks, forKey: SessionSeenStore.seenKey)
      let forgotten = Date(timeIntervalSince1970: installed + 10 * 86_400)
      #expect(SessionSeenStore.unreadEvaluator()("gone", forgotten))
      SessionSeenStore.bootstrapIfNeeded()
      #expect(!SessionSeenStore.unreadEvaluator()("gone", forgotten))
      #expect(SessionSeenStore.unreadEvaluator()("gone", Date()))
    }

    @Test("Everything is marked read in one pass, each chat told to its server")
    func sweep() {
      fresh()
      SessionSeenStore.bootstrapIfNeeded()
      let later = Date().addingTimeInterval(-5)
      UserDefaults.standard.set(
        Date().timeIntervalSince1970 - 3600, forKey: SessionSeenStore.baselineKey)
      #expect(SessionSeenStore.unreadEvaluator()("a", later))
      SessionSeenStore.markSeen(["a", "b"])
      let unread = SessionSeenStore.unreadEvaluator()
      #expect(!unread("a", later))
      #expect(!unread("b", later))
      #expect(MarkIntentStore.holding(.read) == ["a", "b"])
    }
  }
}
