import XCTest
@testable import MicroSurveysSDK

/// Stubs every request: fails the first `failuresLeft` POSTs with a network error, then
/// answers 200, and records the paths of the requests that reached "the server".
final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var failuresLeft = 0
    static var delivered: [String] = []
    static var deliveredBodies: [Data] = []

    static func reset(failures: Int) {
        lock.lock(); defer { lock.unlock() }
        failuresLeft = failures
        delivered = []
        deliveredBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let fail = Self.failuresLeft > 0
        if fail {
            Self.failuresLeft -= 1
        } else {
            Self.delivered.append(request.url?.path ?? "")
            Self.deliveredBodies.append(Self.body(of: request))
        }
        Self.lock.unlock()
        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class OutboxRetryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "outbox-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = APIClient(apiKey: "ms_test_x",
                               baseURL: URL(string: "https://api.example.test")!,
                               session: URLSession(configuration: config),
                               defaults: defaults)
        client.retryBaseDelay = 0.2
        client.retryMaxDelay = 0.4
        return client
    }

    private let context = DeviceContext(platform: "ios", appVersion: "1.0", osVersion: "26.0", locale: "en")

    private func waitFor(_ count: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            StubURLProtocol.lock.lock()
            let n = StubURLProtocol.delivered.count
            StubURLProtocol.lock.unlock()
            if n >= count { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testFailedSendIsRetriedWithoutANewEvent() {
        StubURLProtocol.reset(failures: 2)
        let client = makeClient()
        client.recordImpression(clientId: "imp-1", surveyId: "s1", triggerId: "t1", endUserId: "u1",
                                shownAt: Date(), dismissed: false, context: context)
        // Nothing else is queued: only the retry timer can deliver it.
        waitFor(1)
        XCTAssertEqual(StubURLProtocol.delivered, ["/api/sdk/impressions"])
    }

    func testEverythingQueuedTogetherIsDeliveredInOrder() {
        StubURLProtocol.reset(failures: 0)
        let client = makeClient()
        client.recordImpression(clientId: "imp-1", surveyId: "s1", triggerId: nil, endUserId: "u1",
                                shownAt: Date(), dismissed: false, context: context)
        client.recordResponse(surveyId: "s1", endUserId: "u1", completed: true, submittedAt: Date(),
                              userProps: [:], impressionId: "imp-1", triggerId: nil, context: context,
                              answers: [])
        client.recordImpression(clientId: "imp-2", surveyId: "s1", triggerId: nil, endUserId: "u1",
                                shownAt: Date(), dismissed: true, context: context)
        waitFor(3)
        XCTAssertEqual(StubURLProtocol.delivered,
                       ["/api/sdk/impressions", "/api/sdk/responses", "/api/sdk/impressions"])
    }

    func testDismissResendsTheSameImpression() throws {
        StubURLProtocol.reset(failures: 0)
        let client = makeClient()
        let shownAt = Date(timeIntervalSince1970: 1_800_000_000)
        client.recordImpression(clientId: "imp-1", surveyId: "s1", triggerId: "t1", endUserId: "u1",
                                shownAt: shownAt, dismissed: false, context: context)
        client.recordImpression(clientId: "imp-1", surveyId: "s1", triggerId: "t1", endUserId: "u1",
                                shownAt: shownAt, dismissed: true, context: context)
        waitFor(2)
        let sent = try StubURLProtocol.deliveredBodies.map { body -> [String: Any] in
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            return (json["impressions"] as! [[String: Any]])[0]
        }
        XCTAssertEqual(sent.map { $0["clientId"] as? String }, ["imp-1", "imp-1"])
        XCTAssertEqual(sent.map { $0["dismissed"] as? Bool }, [false, true])
        XCTAssertEqual(sent[0]["shownAt"] as? String, sent[1]["shownAt"] as? String)
    }
}
