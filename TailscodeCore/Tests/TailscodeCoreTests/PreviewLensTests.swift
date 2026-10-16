import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct PreviewLensTests {
    private let treeJSON = """
        {"id":1,"ok":true,"nodeCount":4,"depth":2,"truncated":false,"root":
         {"id":"0","class":"UIWindow","frame":[0,0,402,874],"hidden":false,"alpha":1,"interactive":true,"children":[
          {"id":"0.0","class":"UIView","frame":[0,0,402,874],"hidden":false,"alpha":1,"interactive":true,"children":[
            {"id":"0.0.0","class":"SaveButton","frame":[20,474,362,56],"hidden":false,"alpha":1,"interactive":true,
             "text":"Save","background":"#1F8A3B","textColor":"#FFFFFF","font":{"name":"SFPro-Bold","size":18},
             "accessibility":{"label":"Save","traits":["button"],"isElement":true},"controlTargets":["saveTapped"],"children":[]},
            {"id":"0.0.1","class":"UILabel","frame":[20,100,200,30],"hidden":true,"alpha":1,"interactive":false,"text":"Hidden","children":[]}
          ]}]}}
        """

    @Test func theInspectorsTreeDecodesAndAHitFindsTheDeepestView() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(treeJSON.utf8))
        #expect(tree.nodeCount == 4)
        let chain = PreviewInspectReading.chain(in: tree, x: 200, y: 500)
        #expect(chain.map(\.id) == ["0", "0.0", "0.0.0"])
        #expect(chain.last?.controlTargets == ["saveTapped"])
        #expect(PreviewInspectReading.chain(in: tree, x: 30, y: 110).map(\.id) == ["0"])
    }

    @Test func pixelsMapToPointsThroughTheWindowWidth() throws {
        let hello = try JSONDecoder().decode(
            InspectHello.self,
            from: Data(#"{"app":"PhotoNotes","bundleId":"x","window":{"width":402,"height":874},"scale":3}"#.utf8))
        let point = PreviewInspectReading.points(pixelX: 302, pixelY: 656, pictureWidth: 604, hello: hello)
        #expect(point.x == 201)
        #expect(abs(point.y - 436.6) < 0.1)
    }

    @Test func aViewIsDescribedAsRowsAndAsARequestsContext() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(treeJSON.utf8))
        let button = try #require(PreviewInspectReading.chain(in: tree, x: 200, y: 500).last)
        let rows = PreviewInspectReading.rows(for: button)
        #expect(rows.first { $0.label == "Size" }?.value == "362 × 56")
        #expect(rows.first { $0.label == "Fill" }?.value == "#1F8A3B")
        #expect(rows.first { $0.label == "When pressed" }?.value == "saveTapped")
        let context = PreviewInspectReading.context(for: button, app: "PhotoNotes")
        #expect(context.contains("PhotoNotes"))
        #expect(context.contains("“Save”"))
        #expect(context.contains("362 × 56"))
        #expect(PreviewInspectReading.kindWords("SaveButton") == "a button")
    }

    @Test func findingsAreSaidInPlainWords() throws {
        let json = """
            {"findings":[
             {"kind":"contrast","severity":"fail","nodeId":"1","class":"UILabel","message":"m","measured":1.78,"required":4.5},
             {"kind":"tapTarget","severity":"fail","nodeId":"2","class":"SaveButton","message":"m","measured":[76,30],"required":[44,44]},
             {"kind":"truncation","severity":"warn","nodeId":"3","class":"UILabel","text":"Trip to Oulu","message":"m"}],
             "trustedSystemColors":3}
            """
        let audit = try JSONDecoder().decode(InspectAudit.self, from: Data(json.utf8))
        #expect(audit.findings.count == 3)
        let contrast = PreviewInspectReading.words(for: audit.findings[0])
        #expect(contrast.title == "Hard to read")
        #expect(contrast.detail.contains("1.8"))
        #expect(contrast.fails)
        let tap = PreviewInspectReading.words(for: audit.findings[1])
        #expect(tap.detail.contains("76 × 30"))
        #expect(tap.detail.contains("44 × 44"))
        #expect(!PreviewInspectReading.words(for: audit.findings[2]).fails)
        #expect(PreviewInspectReading.summary(audit) == "3 need attention")
        #expect(PreviewInspectReading.summary(InspectAudit(findings: [], trustedSystemColors: nil)) == "Nothing needs attention on this screen")
    }

    @Test func aDiffIsSummarisedAndItsRegionsBecomeFractions() {
        let report = DiffReport(
            width: 600, height: 1200, changed: 0.041,
            regions: [DiffRegion(x: 60, y: 600, width: 300, height: 120, changed: 0.8)], sameSize: true)
        #expect(PreviewCompareReading.summary(report) == "1 region changed · 4.1% of the pixels")
        let box = PreviewCompareReading.fractions(of: report.regions[0], in: report)
        #expect(box.x == 0.1)
        #expect(box.y == 0.5)
        #expect(box.width == 0.5)
        #expect(box.height == 0.1)
        #expect(PreviewCompareReading.summary(DiffReport(width: 1, height: 1, changed: 0, regions: [], sameSize: true)) == "Nothing changed on screen")
        #expect(PreviewCompareReading.summary(DiffReport(width: 1, height: 1, changed: 1, regions: [], sameSize: false)).contains("changed size"))
    }

    @Test func theNewestTwoPicturesAreTheDefaultPair() {
        func shot(_ id: Int) -> HistoryInfo { HistoryInfo(id: id, at: Date(), title: "t", path: .rebuilt, trigger: "edit", bytes: 1) }
        #expect(PreviewCompareReading.defaultPair([shot(1)]) == nil)
        let pair = PreviewCompareReading.defaultPair([shot(3), shot(1), shot(2)])
        #expect(pair?.before == 2)
        #expect(pair?.after == 3)
    }

    @Test func aShotIsTitledByWhatMadeIt() {
        let start = HistoryInfo(id: 1, at: Date(), title: "ignored", path: nil, trigger: "start", bytes: 1)
        #expect(PreviewCompareReading.title(of: start) == "App opened")
        let edit = HistoryInfo(id: 2, at: Date().addingTimeInterval(-30), title: "Shown in 1.8 s", path: .rebuilt, trigger: "edit", bytes: 1)
        #expect(PreviewCompareReading.title(of: edit) == "Shown in 1.8 s")
        #expect(PreviewCompareReading.detail(of: edit).hasPrefix("Rebuilt and restarted"))
    }

    @Test func everyLensHasATitleAndTheMatrixAsksForTheLooksThatMatter() {
        for lens in PreviewLens.allCases { #expect(!lens.title.isEmpty) }
        let specs = PreviewCompareReading.variantSpecs()
        #expect(specs.map(\.label) == ["Light", "Dark", "Large text", "Largest text", "Right to left"])
        #expect(specs.last?.arguments?.contains("-AppleTextDirection") == true)
    }

    private let overlayJSON = """
        {"id":1,"ok":true,"nodeCount":6,"depth":3,"truncated":false,"root":
         {"id":"0","class":"UIWindow","frame":[0,0,402,874],"alpha":1,"interactive":true,"children":[
          {"id":"0.0","class":"UIView","frame":[0,0,402,874],"alpha":1,"interactive":true,"background":"#F2F2F7","children":[
            {"id":"0.0.0","class":"SaveButton","frame":[20,474,120,56],"alpha":1,"interactive":true,"text":"Save","background":"#3A6DF0","controlTargets":[],"children":[
              {"id":"0.0.0.0","class":"UIButtonLabel","frame":[61,492,38,20],"alpha":1,"interactive":false,"text":"Save","children":[]}]},
            {"id":"0.0.1","class":"_UITouchPassthroughView","frame":[0,0,402,874],"alpha":1,"interactive":true,"children":[
              {"id":"0.0.1.0","class":"ScrollEdgeEffectView","frame":[0,0,402,156],"alpha":0,"interactive":true,"children":[]}]},
            {"id":"0.0.2","class":"UILabel","frame":[20,100,200,30],"alpha":1,"interactive":false,"text":"Photo Notes","background":"#00000000","children":[]}]},
          {"id":"0.1","class":"_UIFloatingBarContainerView","frame":[0,0,402,874],"alpha":1,"interactive":true,"children":[]}]}}
        """
    private let helloJSON = #"{"app":"PhotoNotes","window":{"width":402,"height":874},"scale":3}"#

    @Test func aTransparentLayerOverTheWholeScreenIsNotWhatAPointerLandsOn() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(overlayJSON.utf8))
        #expect(PreviewInspectReading.chain(in: tree, x: 50, y: 500).map(\.id) == ["0", "0.0", "0.0.0"])
        #expect(PreviewInspectReading.chain(in: tree, x: 70, y: 500).last?.id == "0.0.0")
        #expect(PreviewInspectReading.chain(in: tree, x: 30, y: 110).last?.id == "0.0.2")
        #expect(PreviewInspectReading.chain(in: tree, x: 300, y: 700).map(\.id) == ["0", "0.0"])
    }

    @Test func aViewStandsOnThePictureAsFractionsOfItAtAnySize() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(overlayJSON.utf8))
        let hello = try JSONDecoder().decode(InspectHello.self, from: Data(helloJSON.utf8))
        let button = try #require(PreviewInspectReading.path(to: "0.0.0", in: tree).last)
        let place = PreviewInspectReading.place(of: button, in: hello)
        #expect(abs(place.x - 20.0 / 402) < 1e-9)
        #expect(abs(place.y - 474.0 / 874) < 1e-9)
        #expect(abs(place.width - 120.0 / 402) < 1e-9)
        #expect(abs(place.height - 56.0 / 874) < 1e-9)
        let spilling = InspectNode(
            id: "x", className: "UIView", frame: [-20, 860, 500, 100], hidden: nil, alpha: nil, interactive: nil, text: nil,
            placeholder: nil, accessibility: nil, background: nil, textColor: nil, font: nil, controlTargets: nil,
            children: nil, truncated: nil)
        let clipped = PreviewInspectReading.place(of: spilling, in: hello)
        #expect(clipped.x == 0 && clipped.width == 1 && clipped.y + clipped.height == 1)
        let there = PreviewInspectReading.points(fractionX: 0.5, fractionY: 0.25, hello: hello)
        #expect(there.x == 201 && there.y == 218.5)
        let chain = PreviewInspectReading.chain(in: tree, hello: hello, fractionX: 80.0 / 402, fractionY: 500.0 / 874)
        #expect(chain.last?.id == "0.0.0")
    }

    @Test func aPathWalksFromTheWindowToTheViewAndIsEmptyOnceTheViewIsGone() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(overlayJSON.utf8))
        #expect(PreviewInspectReading.path(to: "0.0.0.0", in: tree).map(\.id) == ["0", "0.0", "0.0.0", "0.0.0.0"])
        #expect(PreviewInspectReading.path(to: "9.9", in: tree).isEmpty)
    }

    @Test func aViewIsNamedByItsWordsOrItsKindAndLongPrivateNamesAreCut() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(overlayJSON.utf8))
        #expect(PreviewInspectReading.name(of: try #require(PreviewInspectReading.path(to: "0.0.0", in: tree).last)) == "“Save”")
        #expect(PreviewInspectReading.name(of: try #require(PreviewInspectReading.path(to: "0.1", in: tree).last)) == "_UIFloatingBarContainerView")
        #expect(PreviewInspectReading.shortClass("UIKit.UILabel") == "Label")
        let mangled = "_TtGC5UIKitP10$1c5774cd822FloatingBarHostingViewVS_20FloatingBarContainer_"
        #expect(PreviewInspectReading.shortClass(mangled).count == 28)
        #expect(PreviewInspectReading.shortClass(mangled).hasSuffix("…"))
        let node = try #require(PreviewInspectReading.path(to: "0.0.0", in: tree).last)
        #expect(PreviewInspectReading.crumb(node) == "SaveButton “Save”")
    }

    @Test func aFailingAuditBecomesOneRequestThatNamesEveryFindingAndItsView() throws {
        let tree = try JSONDecoder().decode(InspectTree.self, from: Data(overlayJSON.utf8))
        let json = """
            {"findings":[
             {"kind":"tapTarget","severity":"fail","nodeId":"0.0.0","class":"SaveButton","message":"m","measured":[76,30],"required":[44,44]},
             {"kind":"truncation","severity":"warn","nodeId":"0.0.2","class":"UILabel","text":"Photo Notes","message":"m"}],
             "trustedSystemColors":0}
            """
        let audit = try JSONDecoder().decode(InspectAudit.self, from: Data(json.utf8))
        let request = PreviewInspectReading.fixRequest(findings: audit.findings, tree: tree, app: "PhotoNotes")
        #expect(request.hasPrefix("The preview of PhotoNotes was checked and 2 need attention:"))
        #expect(request.contains("- Hard to press: “Save”. This is 76 × 30. A finger needs at least 44 × 44."))
        #expect(request.contains("- Words cut off: “Photo Notes”."))
        #expect(request.hasSuffix("Please fix them in the code."))
        #expect(PreviewInspectReading.subject(of: audit.findings[0], in: tree) == "SaveButton “Save”")
        #expect(PreviewInspectReading.subject(of: audit.findings[1], in: nil) == "“Photo Notes”")
    }

    @Test func theSixLensesAreChosenByDigitsInTheOrderTheyAreOffered() {
        #expect(PreviewLens.allCases.map(\.digit) == ["1", "2", "3", "4", "5", "6"])
        #expect(PreviewLens(digit: "3") == .inspect)
        #expect(PreviewLens(digit: "4") == .quality)
        #expect(PreviewLens(digit: "7") == nil)
        #expect(PreviewLens.allCases.filter(\.readsViews) == [.inspect, .quality])
    }
}
