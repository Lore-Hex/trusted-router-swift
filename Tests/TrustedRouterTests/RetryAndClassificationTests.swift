import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Status-code → `TrustedRouterError` classification, and retry behavior for
/// rate limits plus apex regional failover.
final class RetryAndClassificationTests: XCTestCase {

    private var router: TrustedRouter!

    override func setUpWithError() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        SequenceProtocol.reset()
        router = try TrustedRouter(options: .init(
            apiKey: "test_key",
            baseUrl: "https://test.local/v1",
            urlSession: URLSession(configuration: config),
            maxRetries: 2
        ))
    }

    func test401MapsToAuthentication() async {
        SequenceProtocol.scripted = [(401, #"{"error":{"message":"bad key"}}"#, nil)]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected auth error")
        } catch TrustedRouterError.authentication(let code, let msg, _) {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(msg, "bad key")
            XCTAssertEqual(SequenceProtocol.served, 1)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test403MapsToPermissionDenied() async {
        SequenceProtocol.scripted = [(403, #"{"error":{"message":"forbidden"}}"#, nil)]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected permission error")
        } catch TrustedRouterError.permissionDenied(let code, _, _) {
            XCTAssertEqual(code, 403)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test404MapsToNotFound() async {
        SequenceProtocol.scripted = [(404, #"{"error":{"message":"gone"}}"#, nil)]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected notFound")
        } catch TrustedRouterError.notFound { /* expected */ }
        catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(SequenceProtocol.served, 1)
    }

    func test501MapsToEndpointNotSupportedWithoutFailoverRetry() async {
        SequenceProtocol.scripted = [
            (501, "", nil),
            (200, #"{}"#, nil),
        ]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected endpointNotSupported")
        } catch TrustedRouterError.endpointNotSupported { /* expected */ }
        catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(SequenceProtocol.served, 1)
    }

    func test400Range4xxMapsToBadRequest() async {
        SequenceProtocol.scripted = [(400, #"{"error":{"message":"bad"}}"#, nil)]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected badRequest")
        } catch TrustedRouterError.badRequest { /* expected */ }
        catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(SequenceProtocol.served, 1)
    }

    func test429MapsToRateLimitAndCarriesRetryAfter() async throws {
        // Five attempts: maxRetries=2 means we should try at most 3 times.
        // Script enough 429s that retries don't recover — confirm rate-limit
        // surfaces with the Retry-After honored.
        SequenceProtocol.scripted = Array(
            repeating: (429, "rate limited", "1"),
            count: 5
        ).map { ($0.0, $0.1, $0.2) }
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected rateLimit")
        } catch TrustedRouterError.rateLimit(_, _, _, let retryAfter) {
            XCTAssertEqual(retryAfter, 1.0)
            XCTAssertEqual(SequenceProtocol.served, 3)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testFailoverableStatusMovesToAnotherDomainAndCanSucceed() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        SequenceProtocol.reset()
        let apexRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 2
        ))

        SequenceProtocol.scripted = [
            (503, #"{"error":{"message":"down"}}"#, nil),
            (503, #"{"error":{"message":"still down"}}"#, nil),
            (200, #"{}"#, nil),
        ]
        let _: EmptyResponse = try await apexRouter.request(method: "GET", path: "/x")
        XCTAssertEqual(SequenceProtocol.served, 3, "should have made all three attempts")
        // Previously this asserted all three attempts hit api.trustedrouter.com
        // and called that failover. Re-sending to the host that just returned
        // 503 is not failover; it is the same request three times.
        XCTAssertEqual(
            SequenceProtocol.requestedHosts,
            ["api.trustedrouter.com", "api.allyrouter.com", "api.uptimerouter.com"]
        )
    }

    func test500DoesNotFailoverRetry() async {
        SequenceProtocol.scripted = [
            (500, #"{"error":{"message":"server error"}}"#, nil),
            (200, #"{}"#, nil),
        ]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected generic error")
        } catch TrustedRouterError.generic(let code, let msg, _) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(msg, "server error")
            XCTAssertEqual(SequenceProtocol.served, 1)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testFailoverableStatusRetriesInPlaceWhenRegionalFailoverDisabled() async throws {
        // This asserted that disabling regionalFailover ALSO stopped retrying
        // 502/503/504 — one switch answering two questions, which is why
        // `served == 1` looked correct. The flag now governs only WHERE a
        // retry goes: a pinned client still retries, on the host it was given.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequenceProtocol.self]
        SequenceProtocol.reset()
        let noFailoverRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 2,
            regionalFailover: false
        ))

        SequenceProtocol.scripted = [
            (502, #"{"error":{"message":"bad gateway"}}"#, nil),
            (200, #"{}"#, nil),
        ]
        let _: EmptyResponse = try await noFailoverRouter.request(method: "GET", path: "/x")
        XCTAssertEqual(SequenceProtocol.served, 2, "a pinned client should still retry a 502")
        XCTAssertEqual(
            Set(SequenceProtocol.requestedHosts),
            ["api.trustedrouter.com"],
            "but it must not move host"
        )
    }

    func testTransportErrorMovesToAnAliasDomainWhenRegionalFailoverEnabled() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportSequenceProtocol.self]
        TransportSequenceProtocol.reset()
        let apexRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 1
        ))

        TransportSequenceProtocol.scripted = [
            .failure(URLError(.cannotConnectToHost)),
            .response(200, #"{}"#),
        ]
        let _: EmptyResponse = try await apexRouter.request(method: "GET", path: "/x")
        XCTAssertEqual(TransportSequenceProtocol.served, 2)
        // A connection failure is the case a dead domain actually produces, and
        // it is the one where retrying the same name is guaranteed to fail
        // again. This previously asserted exactly that as correct.
        XCTAssertEqual(
            TransportSequenceProtocol.requestedHosts,
            ["api.trustedrouter.com", "api.allyrouter.com"]
        )
    }

    func testTransportErrorRetriesInPlaceWhenRegionalFailoverDisabled() async throws {
        // Same correction as above, and a starker one: a dial failure means no
        // server saw the request, so refusing to retry it at all was the least
        // defensible reading of "don't move me to another region".
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportSequenceProtocol.self]
        TransportSequenceProtocol.reset()
        let noFailoverRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 1,
            regionalFailover: false
        ))

        TransportSequenceProtocol.scripted = [
            .failure(URLError(.cannotConnectToHost)),
            .response(200, #"{}"#),
        ]
        let _: EmptyResponse = try await noFailoverRouter.request(method: "GET", path: "/x")
        XCTAssertEqual(TransportSequenceProtocol.served, 2, "should retry the dial failure")
        XCTAssertEqual(
            Set(TransportSequenceProtocol.requestedHosts),
            ["api.trustedrouter.com"],
            "but it must not move host"
        )
    }

    func test4xxOutsideKnownCodesDoesNotRetry() async {
        // 422 isn't in the retryable set. Should fail-fast.
        SequenceProtocol.scripted = [
            (422, #"{"error":{"message":"unprocessable"}}"#, nil),
            (200, #"{}"#, nil),
        ]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected badRequest")
        } catch TrustedRouterError.badRequest {
            XCTAssertEqual(SequenceProtocol.served, 1, "must not retry 422")
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testGenericErrorMessageFallbackUsesStringBody() async {
        SequenceProtocol.scripted = [(400, "plain string error", nil)]
        do {
            let _: EmptyResponse = try await router.request(method: "GET", path: "/x")
            XCTFail("expected error")
        } catch TrustedRouterError.badRequest(_, let msg, _) {
            XCTAssertEqual(msg, "plain string error")
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRegionalAffinityPinsFastestAndFailsOverWithSameIdempotencyKey() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegionalAffinityProtocol.self]
        RegionalAffinityProtocol.reset()
        let affinityRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 1,
            regionalAffinity: true
        ))
        let _: EmptyResponse = try await affinityRouter.request(
            method: "POST",
            path: "/chat/completions",
            body: ["model": "test", "messages": []]
        )

        XCTAssertEqual(RegionalAffinityProtocol.healthCount, 4)
        XCTAssertEqual(RegionalAffinityProtocol.healthAtFirstInference.count, 1)
        XCTAssertEqual(
            RegionalAffinityProtocol.inferenceHosts.first,
            RegionalAffinityProtocol.healthAtFirstInference.first
        )
        XCTAssertEqual(RegionalAffinityProtocol.inferenceHosts.count, 2)
        XCTAssertNotEqual(
            RegionalAffinityProtocol.inferenceHosts[0],
            RegionalAffinityProtocol.inferenceHosts[1]
        )
        let idempotencyKeys = RegionalAffinityProtocol.idempotencyKeys
        XCTAssertEqual(idempotencyKeys.count, 2)
        XCTAssertTrue(idempotencyKeys[0]?.hasPrefix("tr-req-") == true)
        XCTAssertEqual(idempotencyKeys[1], idempotencyKeys[0])
    }

    func testRegionalAffinityKeepsPinnedRegionForProvider429() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegionalAffinityProtocol.self]
        RegionalAffinityProtocol.reset(firstInferenceStatus: 429)
        let affinityRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 1,
            regionalAffinity: true
        ))

        let _: EmptyResponse = try await affinityRouter.request(
            method: "POST",
            path: "/chat/completions",
            body: ["model": "test", "messages": []]
        )

        XCTAssertEqual(
            RegionalAffinityProtocol.inferenceHosts,
            ["api-us-east4.quillrouter.com", "api-us-east4.quillrouter.com"]
        )
    }
}

private final class RegionalAffinityProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var healthCount = 0
    nonisolated(unsafe) static var completedHealthHosts: [String] = []
    nonisolated(unsafe) static var healthAtFirstInference: [String] = []
    nonisolated(unsafe) static var inferenceHosts: [String] = []
    nonisolated(unsafe) static var idempotencyKeys: [String?] = []
    nonisolated(unsafe) static var firstInferenceStatus = 503
    static let fastestHost = "api-us-east4.quillrouter.com"
    private static let lock = NSLock()
    private static let inferenceSeen = NSCondition()
    nonisolated(unsafe) private static var sawInference = false
    private let lifecycleLock = NSLock()
    private var stopped = false

    static func reset(firstInferenceStatus: Int = 503) {
        inferenceSeen.lock()
        sawInference = false
        inferenceSeen.unlock()
        lock.lock()
        defer { lock.unlock() }
        healthCount = 0
        completedHealthHosts = []
        healthAtFirstInference = []
        inferenceHosts = []
        idempotencyKeys = []
        self.firstInferenceStatus = firstInferenceStatus
    }

    /// Unblocks the slower health probes. See `startLoading`.
    private static func signalFirstInference() {
        inferenceSeen.lock()
        sawInference = true
        inferenceSeen.broadcast()
        inferenceSeen.unlock()
    }

    private static func awaitFirstInference() {
        inferenceSeen.lock()
        let deadline = Date(timeIntervalSinceNow: 5)
        while !sawInference && inferenceSeen.wait(until: deadline) {}
        inferenceSeen.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        if request.url?.path == "/health" {
            Self.lock.lock()
            Self.healthCount += 1
            Self.lock.unlock()
            if host == Self.fastestHost {
                respondHealthIfActive(host: host)
                return
            }
            // Every other region answers only after the winner has been picked
            // and the first inference request has gone out, which cannot happen
            // before the race resolves. Ordering the probes by wall-clock delay
            // instead (5ms vs 40ms) made this a race the CI runner regularly
            // lost: under load the 5ms host finishes last, and then "fastest"
            // is whichever region the scheduler happened to favour.
            DispatchQueue.global().async { [self] in
                Self.awaitFirstInference()
                respondHealthIfActive(host: host)
            }
            return
        }

        Self.lock.lock()
        if Self.inferenceHosts.isEmpty {
            Self.healthAtFirstInference = Self.completedHealthHosts
        }
        Self.inferenceHosts.append(host)
        Self.idempotencyKeys.append(request.value(forHTTPHeaderField: "idempotency-key"))
        let status = Self.inferenceHosts.count == 1 ? Self.firstInferenceStatus : 200
        Self.lock.unlock()
        Self.signalFirstInference()
        respond(status: status, body: status == 200 ? "{}" : #"{"error":{"message":"draining"}}"#)
    }

    private func respond(status: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respondHealthIfActive(host: String) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !stopped else { return }
        Self.lock.lock()
        Self.completedHealthHosts.append(host)
        Self.lock.unlock()
        respond(status: 200, body: #"{"status":"ok"}"#)
    }

    override func stopLoading() {
        lifecycleLock.lock()
        stopped = true
        lifecycleLock.unlock()
    }
}

/// URLProtocol that consumes a scripted list of responses, one per request.
/// Each entry is `(statusCode, body, retryAfterSeconds?)`.
private final class SequenceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scripted: [(Int, String, String?)] = []
    nonisolated(unsafe) static var served: Int = 0
    nonisolated(unsafe) static var requestedHosts: [String] = []

    static func reset() {
        scripted = []
        served = 0
        requestedHosts = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host {
            Self.requestedHosts.append(host)
        }
        let idx = Self.served
        Self.served += 1
        let (code, body, retryAfter) = (idx < Self.scripted.count) ? Self.scripted[idx] : (500, "out of script", nil)
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum TransportOutcome {
    case failure(URLError)
    case response(Int, String)
}

private final class TransportSequenceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scripted: [TransportOutcome] = []
    nonisolated(unsafe) static var served: Int = 0
    nonisolated(unsafe) static var requestedHosts: [String] = []

    static func reset() {
        scripted = []
        served = 0
        requestedHosts = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host {
            Self.requestedHosts.append(host)
        }
        let idx = Self.served
        Self.served += 1
        let outcome = idx < Self.scripted.count ? Self.scripted[idx] : .failure(URLError(.unknown))
        switch outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let code, let body):
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
