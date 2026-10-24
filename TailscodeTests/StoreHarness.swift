import Foundation
import MidgarCommerce
import MidgarCore
import OSLog
import StoreKit
import StoreKitTest
import Testing
import UIKit

@testable import Tailscode

/// What every StoreKit test builds: a test session on `Tailscode.storekit`, the store on Tailscode's own
/// configuration with a Midgar ID that is always there and a ledger that answers from a stub, and the Pro
/// access model over that store.
@MainActor
struct StoreHarness {
    static let storeKitFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tailscode.storekit")

    let store: MidgarStore
    let access: ProAccess
    let session: SKTestSession
    let defaults: UserDefaults

    init(askToBuy: Bool = false, resetSession: Bool = true) throws {
        let session = try SKTestSession(contentsOf: Self.storeKitFile)
        if resetSession {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        session.disableDialogs = true
        session.askToBuyEnabled = askToBuy
        LedgerStub.reset()
        self.session = session
        let suite = "tailscode-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        self.defaults = defaults
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-commerce-" + UUID().uuidString, isDirectory: true)
        store = MidgarStore(
            configuration: TailscodeMidgar.storeConfiguration(directory: directory),
            identity: StubIdentity(),
            http: LedgerStub.client())
        access = ProAccess(store: store, sellsPro: true, defaults: defaults)
    }

    /// A second launch of the app over the same StoreKit session: a new store and a new model with nothing
    /// cached, which is what the first launch after this change looks like for an earlier buyer.
    func relaunched() throws -> StoreHarness {
        try StoreHarness(askToBuy: false, resetSession: false)
    }

    func product(_ id: String) async throws -> StoreProduct {
        let (pro, tips) = await access.products()
        return try #require(([pro].compactMap { $0 } + tips).first { $0.id == id })
    }

    /// Buys `id` with the confirmation anchored to the host app's window scene, as the sheet is. A
    /// scene-less purchase in a test host never completes, because StoreKit finds no window to confirm in.
    func buy(_ id: String) async throws -> ProAccess.PurchaseOutcome {
        let product = try await product(id)
        let scene = try #require(UIApplication.shared.connectedScenes.first)
        return try await access.purchase(product, confirmIn: scene)
    }

    /// The `appAccountToken` of the latest transaction StoreKit holds for `id`.
    func accountToken(of id: String) async -> UUID? {
        guard case .verified(let transaction)? = await Transaction.latest(for: id) else { return nil }
        return transaction.appAccountToken
    }
}

/// Polls `condition` until it holds or `timeout` passes, for the StoreKit changes that reach the store a
/// moment after the session makes them.
@MainActor
func eventually(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}

/// A Midgar ID that is always there, in the UUID form `appAccountToken` takes.
struct StubIdentity: MidgarStoreIdentity {
    static let midgarID = "3B7E2A10-5C4D-4E6F-9A81-2D3C4B5A6F70"

    var midgarId: String {
        get async throws { Self.midgarID }
    }
}

/// The ledger the store talks to in these tests: it answers the entitlements query with nothing for the
/// stub Midgar ID and counts transaction reports. A test session signs its transactions with Xcode's local
/// certificate, so the store never reports them and the count stays at zero.
final class LedgerStub: URLProtocol {
    private static let host = "ledger.tailscode-tests.invalid"
    private static let reports = OSAllocatedUnfairLock(initialState: 0)

    static var reportCount: Int { reports.withLock { $0 } }

    static func reset() {
        reports.withLock { $0 = 0 }
    }

    static func client() -> MidgarHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LedgerStub.self]
        return MidgarHTTPClient(
            configuration: MidgarHTTPConfiguration(
                baseURL: URL(string: "https://\(host)")!,
                appID: TailscodeMidgar.appID,
                session: URLSession(configuration: configuration),
                timeout: 5))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body) = Self.answer(method: request.httpMethod ?? "GET", path: url.path)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(method: String, path: String) -> (Int, String) {
        switch (method, path) {
        case ("POST", "/v1/ledger/transactions"):
            reports.withLock { $0 += 1 }
            return (200, #"{"ok":true}"#)
        case ("GET", "/v1/ledger/entitlements"):
            let now = Int(Date().timeIntervalSince1970 * 1000)
            return (
                200,
                #"{"midgarId":"\#(StubIdentity.midgarID)","environment":"Sandbox","serverTime":\#(now),"entitlements":[]}"#
            )
        default:
            return (404, "{}")
        }
    }
}
