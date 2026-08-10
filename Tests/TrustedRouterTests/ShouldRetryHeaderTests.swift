import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The gateway's x-should-retry verdict overrides our status heuristics.
///
/// A status code cannot say whether a provider already ran: a 502 from "could
/// not reach the provider" and a 502 from "the generation succeeded and then
/// settlement failed" are indistinguishable here, and only the second is
/// dangerous to re-send.
final class ShouldRetryHeaderTests: XCTestCase {

    private func router(_ retries: Int = 3, failover: Bool = true) throws -> TrustedRouter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ShouldRetryProtocol.self]
        return try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: retries,
            regionalFailover: failover
        ))
    }

    func testALabelledSpent502IsNotRetriedAndDoesNotMoveDomains() async throws {
        ShouldRetryProtocol.reset()
        ShouldRetryProtocol.scripted = [(502, #"{"error":{"message":"settlement failed"}}"#,
                                        ["x-should-retry": "false"])]
        let client = try router()

        do {
            let _: EmptyResponse = try await client.request(method: "GET", path: "/x")
            XCTFail("expected the 502 to surface")
        } catch { /* expected */ }

        XCTAssertEqual(ShouldRetryProtocol.requestedHosts.count, 1,
                       "the gateway said a provider already ran")
        XCTAssertEqual(Set(ShouldRetryProtocol.requestedHosts), ["api.trustedrouter.com"])
    }

    func testAnUnlabelled502StillFailsOver() async throws {
        ShouldRetryProtocol.reset()
        ShouldRetryProtocol.scripted = [
            (502, #"{"error":{"message":"unavailable"}}"#, [:]),
            (200, "{}", [:]),
        ]
        let client = try router()

        let _: EmptyResponse = try await client.request(method: "GET", path: "/x")
        XCTAssertTrue(ShouldRetryProtocol.requestedHosts.contains("api.allyrouter.com"),
                      "lost failover: \(ShouldRetryProtocol.requestedHosts)")
    }

    func testALabelledRetryable400IsRetried() async throws {
        ShouldRetryProtocol.reset()
        ShouldRetryProtocol.scripted = [
            (400, #"{"error":{"message":"transient"}}"#, ["x-should-retry": "true"]),
            (200, "{}", [:]),
        ]
        let client = try router(2)

        let _: EmptyResponse = try await client.request(method: "GET", path: "/x")
        XCTAssertEqual(ShouldRetryProtocol.served, 2, "server said retry and we did not")
    }

    /// regionalFailover used to answer two questions at once: turning it off
    /// also stopped retrying 502/503/504 entirely. It now governs only WHERE.
    func testAPinnedClientStillRetriesInPlace() async throws {
        ShouldRetryProtocol.reset()
        ShouldRetryProtocol.scripted = [
            (503, #"{"error":{"message":"draining"}}"#, [:]),
            (200, "{}", [:]),
        ]
        let client = try router(2, failover: false)

        let _: EmptyResponse = try await client.request(method: "GET", path: "/x")
        XCTAssertEqual(ShouldRetryProtocol.served, 2, "a pinned client should still retry a 503")
        XCTAssertEqual(Set(ShouldRetryProtocol.requestedHosts), ["api.trustedrouter.com"],
                       "but must not move host")
    }

    /// Added with the transport-engine extraction: pins the count-1 bound on
    /// THE single candidate-advance site. With the bound removed, exhausting
    /// the candidate list would index past its end instead of staying pinned
    /// to the last alias domain.
    func testExhaustedCandidatesStayPinnedToTheLastAliasDomain() async throws {
        ShouldRetryProtocol.reset()
        ShouldRetryProtocol.scripted = [(502, #"{"error":{"message":"unavailable"}}"#, [:])]
        let client = try router(3)

        do {
            let _: EmptyResponse = try await client.request(method: "GET", path: "/x")
            XCTFail("expected the exhausted 502 to surface")
        } catch { /* expected */ }

        XCTAssertEqual(ShouldRetryProtocol.served, 4, "maxRetries=3 means four attempts")
        XCTAssertEqual(
            ShouldRetryProtocol.requestedHosts,
            ["api.trustedrouter.com", "api.allyrouter.com", "api.uptimerouter.com",
             "api.uptimerouter.com"],
            "after the list is exhausted, further retries stay on the last alias"
        )
    }

    func testRetryAfterMsIsHonoredAndBeatsRetryAfter() async throws {
        // 30s would blow the test timeout and 10ms cannot; the gap is the assertion.
        ShouldRetryProtocol.reset()
        ShouldRetryProtocol.scripted = [
            (429, #"{"error":{"message":"slow down"}}"#,
             ["retry-after-ms": "10", "retry-after": "30"]),
            (200, "{}", [:]),
        ]
        let client = try router(1)

        let started = Date()
        let _: EmptyResponse = try await client.request(method: "GET", path: "/x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0,
                          "retry-after-ms did not win over retry-after")
    }
}

/// Serves a scripted sequence and records the domain the SDK chose. URLProtocol
/// intercepts before DNS, so the real hostnames are never resolved.
final class ShouldRetryProtocol: URLProtocol {
    nonisolated(unsafe) static var scripted: [(Int, String, [String: String])] = []
    nonisolated(unsafe) static var requestedHosts: [String] = []
    nonisolated(unsafe) static var served = 0

    static func reset() {
        scripted = []
        requestedHosts = []
        served = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requestedHosts.append(request.url?.host ?? "")
        guard !Self.scripted.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let index = min(Self.served, Self.scripted.count - 1)
        let (status, body, extra) = Self.scripted[index]
        Self.served += 1
        var headers = ["Content-Type": "application/json"]
        for (name, value) in extra { headers[name] = value }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
