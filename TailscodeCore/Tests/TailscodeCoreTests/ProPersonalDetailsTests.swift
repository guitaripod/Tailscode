import Foundation
import Testing

@testable import TailscodeCore

@Suite("Pro personal details")
struct ProPersonalDetailsTests {
    private typealias Facts = ProPersonalDetails.Facts

    @Test("Turns are counted from the threshold and not one before")
    func turnsThreshold() {
        let below = Facts(turns: ProPersonalDetails.turnsWorthCounting - 1)
        let at = Facts(turns: ProPersonalDetails.turnsWorthCounting)
        #expect(ProPersonalDetails.turnsLine(below) == nil)
        #expect(ProPersonalDetails.turnsLine(at) == "10 turns finished with your agents")
        #expect(ProPersonalDetails.turnsLine(Facts(turns: 1_482)) == "1482 turns finished with your agents")
    }

    @Test("The threshold is the invitation's own")
    func sharedThreshold() {
        #expect(ProPersonalDetails.turnsWorthCounting == ProInvitation.minimumTurns)
    }

    @Test("The sheet leads with the person's turns, or with what Pro is without enough of them")
    func headline() {
        #expect(ProPersonalDetails.headline(Facts()) == ProOffer.headline)
        #expect(ProPersonalDetails.headline(Facts(turns: 9, connected: ["studio"])) == ProOffer.headline)
        #expect(ProPersonalDetails.headline(Facts(turns: 64)) == "64 turns finished with your agents")
    }

    @Test("The servers perk names the one server a free copy connects")
    func oneServer() {
        #expect(
            ProPersonalDetails.serversLine(Facts(connected: ["studio"]))
                == "You connect to studio. Pro adds every other machine on your tailnet to the same session list.")
    }

    @Test("Nothing is said about servers with none saved, or with several and none resting")
    func noServerLine() {
        #expect(ProPersonalDetails.serversLine(Facts()) == nil)
        #expect(ProPersonalDetails.serversLine(Facts(turns: 500)) == nil)
        #expect(ProPersonalDetails.serversLine(Facts(connected: ["studio", "mini"])) == nil)
    }

    @Test("Resting servers are named first, however many stay connected")
    func restingServers() {
        let one = Facts(connected: ["studio"], resting: ["mini"])
        let two = Facts(connected: ["studio"], resting: ["mini", "atlas"])
        #expect(
            ProPersonalDetails.serversLine(one)
                == "Resting now: mini. Pro keeps every server connected, in one session list across your tailnet.")
        let named = ["mini", "atlas"].formatted(.list(type: .and))
        #expect(ProPersonalDetails.serversLine(two)?.contains(named) == true)
        #expect(ProPersonalDetails.serversLine(two)?.contains("studio") == false)
    }

    @Test("Only the servers perk changes, and only when there is something to tell")
    func perks() {
        #expect(ProPersonalDetails.perks(Facts()) == ProOffer.perks())
        #expect(ProPersonalDetails.perks(Facts(turns: 99), liveActivities: true) == ProOffer.perks(liveActivities: true))

        let facts = Facts(connected: ["studio"])
        for liveActivities in [false, true] {
            let general = ProOffer.perks(liveActivities: liveActivities)
            let perks = ProPersonalDetails.perks(facts, liveActivities: liveActivities)
            #expect(perks.count == general.count)
            #expect(perks.first?.symbol == general.first?.symbol)
            #expect(perks.first?.text == ProPersonalDetails.serversLine(facts))
            #expect(Array(perks.dropFirst()) == Array(general.dropFirst()))
        }
    }

    @Test("Live Activities are offered only where the client has them, and Delegate stays last")
    func livePerk() {
        #expect(ProOffer.perks().count == 3)
        #expect(ProOffer.perks(liveActivities: true).count == 4)
        #expect(ProOffer.perks(liveActivities: true).last == DelegateProGate.perk)
    }

    @Test("Nothing the offer says asks for support, thanks or funding")
    func givesAndNeverAsks() {
        let words =
            [ProOffer.headline, ProOffer.pitch, ProOffer.owned, ProOffer.ownedDetail, ProOffer.requirement]
            + ProOffer.perks(liveActivities: true).map(\.text)
            + [ProInvitation.body(.week), ProInvitation.body(.pro), ProInvitation.primaryAction(.week, price: nil)]
        for line in words {
            let lowered = line.lowercased()
            for asking in ["support", "fund", "thank", "tip", "donat"] {
                #expect(!lowered.contains(asking), "\(line)")
            }
        }
    }
}
