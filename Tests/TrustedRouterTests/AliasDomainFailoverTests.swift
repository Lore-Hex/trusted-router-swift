import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The domain is a single point of failure sitting above the whole deployment.
///
/// Three names resolve to the same attested enclaves, on separate DNS
/// providers. These tests prove a client actually reaches the second one when
/// the first stops answering. The retry machinery was already here — a
/// `baseIndex`, an advance on transport errors, an advance on 502/503/504 —
/// but every advance is guarded by `baseIndex < inferenceURLs.count - 1`, and
/// the candidate list had one entry for any client with an injected
/// `URLSession`. Length 1 makes that guard permanently false.
final class AliasDomainFailoverTests: XCTestCase {

    func testTheDefaultCandidateListHasMoreThanOneEntry() {
        let urls = aliasFailoverURLs(
            primaryBaseURL: TrustedRouterConstants.defaultAPIBaseURL,
            regionalFailover: true
        )
        XCTAssertGreaterThan(urls.count, 1, "failover cannot engage with a single candidate")
        XCTAssertEqual(urls.first, TrustedRouterConstants.defaultAPIBaseURL, "primary must be first")
        for alias in TrustedRouterConstants.aliasAPIBaseURLs {
            XCTAssertTrue(urls.contains(alias), "missing alias \(alias)")
        }
    }

    func testATrailingSlashOnTheDefaultStillActivatesTheAliases() {
        // Comparing a stored base URL against the raw constant is exactly how
        // this degrades back to one entry without any test noticing.
        XCTAssertGreaterThan(
            aliasFailoverURLs(
                primaryBaseURL: "https://api.trustedrouter.com/v1/",
                regionalFailover: true
            ).count,
            1
        )
    }

    func testACustomBaseURLIsNeverRedirectedToAPublicAlias() {
        // A private deployment or a test server must get exactly what was asked
        // for. Silently sending that traffic to a public alias is worse than
        // failing.
        XCTAssertEqual(
            aliasFailoverURLs(primaryBaseURL: "https://my.internal/v1", regionalFailover: true),
            ["https://my.internal/v1"]
        )
    }

    func testDisablingRegionalFailoverPinsTheClientToOneHost() {
        XCTAssertEqual(
            aliasFailoverURLs(
                primaryBaseURL: TrustedRouterConstants.defaultAPIBaseURL,
                regionalFailover: false
            ),
            [TrustedRouterConstants.defaultAPIBaseURL]
        )
    }

    func testAnInjectedURLSessionStillGetsTheAliases() throws {
        // An injected session disables the regional selector, and that fallback
        // used to be a one-element list — so every app that configures its own
        // caching, timeouts, or delegate had no failover at all.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AliasSequenceProtocol.self]
        let router = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config)
        ))
        XCTAssertNil(router.regionalEndpointSelector, "selector should be off here")
        XCTAssertGreaterThan(router.aliasBaseURLs.count, 1)
    }

    func testADeadPrimaryDomainReachesAnAlias() async throws {
        // The real scenario: the primary domain does not resolve at all. The
        // failure happens before a byte is written, so no server saw the
        // request and moving domains cannot double-execute anything.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AliasSequenceProtocol.self]
        AliasSequenceProtocol.reset()
        AliasSequenceProtocol.deadHosts = ["api.trustedrouter.com"]
        AliasSequenceProtocol.scripted = [(200, #"{}"#)]
        let router = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 2
        ))

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(AliasSequenceProtocol.requestedHosts.first, "api.trustedrouter.com",
                       "primary must be attempted first")
        XCTAssertTrue(AliasSequenceProtocol.requestedHosts.contains("api.allyrouter.com"),
                      "never reached an alias: \(AliasSequenceProtocol.requestedHosts)")
    }

    func testA500RetriesInPlaceWithoutMovingToAnotherDomain() async throws {
        // 500 is retryable, but not failoverable. A replay-safe request may be
        // retried on the same host; it must never move to an alias.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AliasSequenceProtocol.self]
        AliasSequenceProtocol.reset()
        AliasSequenceProtocol.scripted = [
            (500, #"{"error":{"message":"boom"}}"#),
            (200, #"{}"#),
        ]
        let router = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            maxRetries: 2
        ))

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(Set(AliasSequenceProtocol.requestedHosts), ["api.trustedrouter.com"],
                       "a 500 leaked to another domain")
        XCTAssertEqual(AliasSequenceProtocol.served, 2, "the in-host retry must recover")
    }

    func testTheAliasesSurviveAFailedHealthRace() async {
        // No region answering is precisely when the aliases matter; collapsing
        // to one host there would delete failover at the worst moment.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AliasSequenceProtocol.self]
        AliasSequenceProtocol.reset()
        AliasSequenceProtocol.deadHosts = ["*"]
        let selector = RegionalEndpointSelector(
            primaryBaseURL: TrustedRouterConstants.defaultAPIBaseURL,
            urlSession: URLSession(configuration: config),
            timeout: 0.2
        )

        let endpoints = await selector.endpoints()

        XCTAssertGreaterThan(endpoints.count, 1, "a failed race must not remove failover")
        XCTAssertEqual(endpoints.first, TrustedRouterConstants.defaultAPIBaseURL)
        for alias in TrustedRouterConstants.aliasAPIBaseURLs {
            XCTAssertTrue(endpoints.contains(alias), "missing alias \(alias)")
        }
    }
}

/// Serves a scripted sequence, and fails outright for hosts named dead.
///
/// `URLProtocol` intercepts before any DNS lookup, so the real hostnames are
/// never resolved and these tests make no network call.
final class AliasSequenceProtocol: URLProtocol {
    nonisolated(unsafe) static var scripted: [(Int, String)] = []
    nonisolated(unsafe) static var deadHosts: Set<String> = []
    nonisolated(unsafe) static var requestedHosts: [String] = []
    nonisolated(unsafe) static var served = 0

    static func reset() {
        scripted = []
        deadHosts = []
        requestedHosts = []
        served = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.requestedHosts.append(host)
        if Self.deadHosts.contains(host) || Self.deadHosts.contains("*") {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let index = min(Self.served, max(0, Self.scripted.count - 1))
        guard !Self.scripted.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, body) = Self.scripted[index]
        Self.served += 1
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
}
