import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Header channel of the client-telemetry contract v1 (§3.2, §6.1, §6.3,
/// §6.4). Every wire assertion here drives the REAL transport engine
/// (`withTransportRetries`) through a scripted `URLProtocol`, exactly like
/// the failover tests — never a reimplementation of the header logic. The
/// engine-driven clients pass an explicit `telemetry:` option so the suite
/// is hermetic against the CI environment; the environment precedence is
/// covered separately through the resolver's injected dictionary, mirroring
/// how the Python SDK takes `environ` as a parameter.
final class ClientTelemetryHeaderTests: XCTestCase {

    private func makeRouter(
        baseUrl: String? = nil,
        telemetry: Bool? = true,
        maxRetries: Int = 2
    ) throws -> TrustedRouter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryCaptureProtocol.self]
        return try TrustedRouter(options: .init(
            apiKey: "test_key",
            baseUrl: baseUrl,
            urlSession: URLSession(configuration: config),
            maxRetries: maxRetries,
            telemetry: telemetry
        ))
    }

    private func assertMatches(
        _ value: String?,
        _ pattern: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let value else {
            XCTFail("expected a header, got nil", file: file, line: line)
            return
        }
        XCTAssertNotNil(
            value.range(of: pattern, options: .regularExpression),
            "\(value) does not match \(pattern)",
            file: file,
            line: line
        )
    }

    // MARK: - §6.4: header on attempt 0, exact bytes

    func testAttemptZeroNonStreamingHeaderIsExactBytes() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter()

        let _: EmptyResponse = try await router.request(method: "POST", path: "/chat/completions", body: ["model": "m", "messages": []])

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, ["v=1;a=0;s=0"])
    }

    func testAttemptZeroStreamingHeaderIsExactBytes() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "data: [DONE]\n\n")]
        let router = try makeRouter()

        _ = try await router.rawStreamRequest(
            method: "POST",
            path: "/chat/completions",
            body: Data("{}".utf8)
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, ["v=1;a=0;s=1"])
    }

    // MARK: - §6.4: retry context rides the next attempt

    func testTransportTimeoutRetryCarriesPreviousAttemptContext() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [
            .failure(URLError(.timedOut)),
            .response(200, "{}"),
        ]
        let router = try makeRouter(maxRetries: 1)

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders.count, 2)
        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders.first, "v=1;a=0;s=0")
        // A top-level timeout is outcome `timeout`; URLSession cannot see the
        // connect/read phase, and no response headers had arrived, so the
        // class is connect_timeout (§5.2). The move to the alias sets fo=1.
        assertMatches(
            TelemetryCaptureProtocol.telemetryHeaders.last ?? nil,
            "^v=1;a=1;po=timeout;pc=connect_timeout;ph=apex;pm=[0-9]{1,7};sm=[0-9]{1,7};s=0;fo=1$"
        )
        XCTAssertEqual(
            TelemetryCaptureProtocol.requestedHosts,
            ["api.trustedrouter.com", "api.allyrouter.com"]
        )
    }

    /// The contract's own §3.2 retry example, byte for byte, from the real
    /// recorder with an injected clock: a connect timeout surfaced inside a
    /// wrapped transport error (outcome transport_error, class
    /// connect_timeout) on the apex, then a move to an alias.
    func testContractRetryExampleGoldenVector() {
        var clock = 0.0
        let recorder = RequestRecorder(streaming: true, now: { clock })

        recorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        clock = 10.0125
        recorder.onTransportError(NSError(
            domain: "TestTransport",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError]
        ))
        recorder.onMoved()
        clock = 10.5305
        recorder.beginAttempt(baseURL: TrustedRouterConstants.aliasAPIBaseURLs[0])

        XCTAssertEqual(
            recorder.headerValue(),
            "v=1;a=1;po=transport_error;pc=connect_timeout;ph=apex;pm=10012;sm=10530;s=1;fo=1"
        )
    }

    func testAttemptZeroGoldenVectorsFromTheRecorder() {
        let streaming = RequestRecorder(streaming: true, now: { 0 })
        streaming.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        XCTAssertEqual(streaming.headerValue(), "v=1;a=0;s=1")

        let buffered = RequestRecorder(streaming: false, now: { 0 })
        buffered.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        XCTAssertEqual(buffered.headerValue(), "v=1;a=0;s=0")
    }

    // MARK: - §3.2 exclusions: custom bases and the control plane

    func testCustomBaseURLNeverSendsTheHeaderEvenWhenTelemetryIsForcedOn() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter(baseUrl: "https://my.internal/v1", telemetry: true)
        XCTAssertTrue(router.telemetryEnabled, "exclusion must not depend on the default-off")

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil],
                       "a self-hosted gateway is not TrustedRouter's to measure")
        XCTAssertEqual(TelemetryCaptureProtocol.requestedHosts, ["my.internal"],
                       "the request itself must still be sent")
    }

    func testControlPlaneCallSendsNoHeader() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter(telemetry: true)
        XCTAssertTrue(router.telemetryEnabled, "absence must come from the plane, not opt-out")

        let _: EmptyResponse = try await router.request(method: "GET", path: "/auth/session", plane: .control)

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil])
        XCTAssertEqual(TelemetryCaptureProtocol.requestedHosts, ["trustedrouter.com"])
    }

    func testOptedOutClientSendsNoHeaderButKeepsUserAgent() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter(telemetry: false)
        XCTAssertFalse(router.telemetryEnabled)

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil])
        XCTAssertEqual(TelemetryCaptureProtocol.userAgents, [TrustedRouter.userAgent],
                       "opt-out suppresses x-tr-client only; the User-Agent stays (§6.3)")
    }

    // MARK: - §6.3 opt-out precedence (injected environment)

    func testOptOutPrecedenceMatrix() {
        let apex = TrustedRouterConstants.defaultAPIBaseURL
        let control = TrustedRouterConstants.defaultControlBaseURL

        func resolved(
            _ explicit: Bool?,
            base: String = apex,
            controlBase: String = control,
            env: [String: String] = [:]
        ) -> Bool {
            ClientTelemetry.resolveEnabled(
                explicit: explicit,
                baseURL: base,
                controlBaseURL: controlBase,
                environment: env
            )
        }

        // Explicit argument beats every environment signal.
        XCTAssertFalse(resolved(false, env: ["TRUSTEDROUTER_TELEMETRY": "1"]))
        XCTAssertTrue(resolved(true, env: ["TRUSTEDROUTER_TELEMETRY": "0", "DO_NOT_TRACK": "1"]))

        // TRUSTEDROUTER_TELEMETRY beats DO_NOT_TRACK in both directions.
        XCTAssertTrue(resolved(nil, env: ["TRUSTEDROUTER_TELEMETRY": "1", "DO_NOT_TRACK": "1"]))
        for disable in ["0", "false", "off", "no", " OFF "] {
            XCTAssertFalse(resolved(nil, env: ["TRUSTEDROUTER_TELEMETRY": disable]),
                           "\(disable) must disable")
        }
        for enable in ["1", "true", "on", "yes", " Yes "] {
            XCTAssertTrue(resolved(nil, env: ["TRUSTEDROUTER_TELEMETRY": enable]),
                          "\(enable) must enable")
        }

        // DO_NOT_TRACK=1 disables when the SDK variable says nothing.
        XCTAssertFalse(resolved(nil, env: ["DO_NOT_TRACK": "1"]))
        XCTAssertTrue(resolved(nil, env: ["DO_NOT_TRACK": "0"]))

        // Default: on only for known TR inference hosts under the real
        // control plane; custom bases and custom control planes default off.
        XCTAssertTrue(resolved(nil))
        XCTAssertTrue(resolved(nil, base: TrustedRouterConstants.regionBaseURLs[0]))
        XCTAssertTrue(resolved(nil, base: TrustedRouterConstants.aliasAPIBaseURLs[1]))
        XCTAssertTrue(resolved(nil, controlBase: "https://eu.trustedrouter.com/v1"))
        XCTAssertFalse(resolved(nil, base: "https://my.internal/v1"))
        XCTAssertFalse(resolved(nil, controlBase: "https://control.my.internal/v1"))
        XCTAssertFalse(resolved(nil, controlBase: "http://trustedrouter.com/v1"),
                       "a non-https control plane is not the real control plane")
        // An unrecognised value falls through to the default, not to off.
        XCTAssertTrue(resolved(nil, env: ["TRUSTEDROUTER_TELEMETRY": "maybe"]))
    }

    // MARK: - §5.2 host mapping

    func testHostEnumMapping() {
        XCTAssertEqual(ClientTelemetry.hostEnum("https://api.trustedrouter.com/v1"), "apex")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://api.allyrouter.com/v1"), "ally")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://api.uptimerouter.com/v1"), "uptime")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://api-us-central1.quillrouter.com/v1"), "us_central1")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://api-us-east4.quillrouter.com/v1"), "us_east4")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://api-europe-west4.quillrouter.com/v1"), "europe_west4")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://trustedrouter.com/v1"), "control")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://status.trustedrouter.com/status.json"), "control")
        XCTAssertEqual(ClientTelemetry.hostEnum("http://api.trustedrouter.com/v1"), "custom",
                       "scheme is part of the identity: plain http is not the apex")
        XCTAssertEqual(ClientTelemetry.hostEnum("https://my.internal/v1"), "custom")
        XCTAssertEqual(ClientTelemetry.hostEnum("not a url"), "custom")
        XCTAssertEqual(ClientTelemetry.hostEnum(""), "custom")
    }

    // MARK: - §5.2 transport error classification

    func testTransportErrorClassification() {
        func classify(_ error: Error, responseOpened: Bool = false) -> String {
            ClientTelemetry.classifyTransportError(error, responseOpened: responseOpened)
        }

        XCTAssertEqual(classify(URLError(.cannotFindHost)), "dns")
        XCTAssertEqual(classify(URLError(.dnsLookupFailed)), "dns")
        XCTAssertEqual(classify(URLError(.secureConnectionFailed)), "tls")
        XCTAssertEqual(classify(URLError(.serverCertificateUntrusted)), "tls")
        XCTAssertEqual(classify(URLError(.cannotConnectToHost)), "connect_refused")
        XCTAssertEqual(classify(URLError(.timedOut)), "connect_timeout")
        XCTAssertEqual(classify(URLError(.timedOut), responseOpened: true), "read_timeout")
        XCTAssertEqual(classify(URLError(.networkConnectionLost)), "reset")
        XCTAssertEqual(classify(URLError(.badServerResponse)), "protocol_error")
        XCTAssertEqual(classify(URLError(.cannotParseResponse)), "protocol_error")
        XCTAssertEqual(classify(URLError(.unknown)), "unknown")

        XCTAssertEqual(
            classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))),
            "connect_refused"
        )
        XCTAssertEqual(
            classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))),
            "reset"
        )
        XCTAssertEqual(
            classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))),
            "io_error"
        )

        // The class survives one level of wrapping — the underlying-error
        // chain is walked exactly like py's __cause__/__context__ chain.
        let wrapped = NSError(
            domain: "Wrapper",
            code: 7,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost) as NSError]
        )
        XCTAssertEqual(classify(wrapped), "dns")
        XCTAssertEqual(classify(NSError(domain: "Opaque", code: 1)), "unknown")
    }

    func testTimeoutOutcomeIsDecidedByTheTopLevelError() {
        XCTAssertTrue(ClientTelemetry.isTimeoutError(URLError(.timedOut)))
        let wrapped = NSError(
            domain: "Wrapper",
            code: 7,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError]
        )
        XCTAssertFalse(ClientTelemetry.isTimeoutError(wrapped),
                       "a buried timeout classifies as pc=connect_timeout but outcome transport_error")
    }

    // MARK: - §3.2 bounds and grammar

    func testWorstCaseHeaderStaysWithinTheByteBudget() {
        var clock = 0.0
        let recorder = RequestRecorder(streaming: true, now: { clock })
        // 99 failed attempts of an hour each, so every numeric field sits at
        // its clamp and the attempt index at the contract's 0..99 ceiling.
        for _ in 0..<99 {
            recorder.beginAttempt(baseURL: TrustedRouterConstants.regionBaseURLs[2])
            clock += 3_600.0
            recorder.onTransportError(URLError(.timedOut))
            recorder.onMoved()
        }
        recorder.beginAttempt(baseURL: TrustedRouterConstants.regionBaseURLs[2])
        guard let header = recorder.headerValue() else {
            return XCTFail("worst case must still emit")
        }
        XCTAssertLessThanOrEqual(header.utf8.count, ClientTelemetry.maxHeaderBytes)
        XCTAssertEqual(
            header,
            "v=1;a=99;po=timeout;pc=connect_timeout;ph=europe_west4;pm=3600000;sm=3600000;s=1;fo=1"
        )
        for pair in header.split(separator: ";") {
            let value = String(pair.split(separator: "=", maxSplits: 1)[1])
            XCTAssertTrue(ClientTelemetry.isValidHeaderValue(value), "bad value \(value)")
        }
    }

    func testOutOfGrammarValuesSendNothing() {
        XCTAssertNil(ClientTelemetry.assembleHeaderLine([("v", "1"), ("po", "HTTP ERROR")]),
                     "uppercase and spaces are out of grammar")
        XCTAssertNil(ClientTelemetry.assembleHeaderLine([("v", "")]),
                     "empty values are out of grammar")
        XCTAssertNil(ClientTelemetry.assembleHeaderLine([("v", String(repeating: "a", count: 25))]),
                     "25 characters exceeds the value bound")
        let oversized = (0..<20).map { ("k\($0)", String(repeating: "x", count: 24)) }
        XCTAssertNil(ClientTelemetry.assembleHeaderLine(oversized),
                     "over 160 bytes sends nothing")
        XCTAssertEqual(
            ClientTelemetry.assembleHeaderLine([("v", "1"), ("a", "0"), ("s", "1")]),
            "v=1;a=0;s=1"
        )
    }

    func testClampedMillisecondsNeverTraps() {
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(-5), 0)
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(0), 0)
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(1.5), 1500)
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(10_000_000), 3_600_000)
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(.infinity), 0)
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(-.infinity), 0)
        XCTAssertEqual(ClientTelemetry.clampedMilliseconds(.nan), 0)
    }

    // MARK: - §3.1 User-Agent grammar

    func testUserAgentMatchesTheContractGrammar() {
        let semver = "(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)"
            + "(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?"
            + "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?"
        let pattern = "^trusted-router-swift/\(semver)(?: [a-z]{1,10}/[0-9A-Za-z.+-]{1,24})?$"
        let agent = TrustedRouter.userAgent
        XCTAssertNotNil(
            agent.range(of: pattern, options: .regularExpression),
            "\(agent) drifted out of the §3.1 grammar the enclave parses"
        )
    }
}

/// Scripted transport fake for the telemetry tests: serves each entry once,
/// recording the host, `x-tr-client`, and `user-agent` of every request the
/// engine actually put on the wire.
final class TelemetryCaptureProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case response(Int, String)
        case failure(URLError)
    }

    nonisolated(unsafe) static var scripted: [Outcome] = []
    nonisolated(unsafe) static var served = 0
    nonisolated(unsafe) static var requestedHosts: [String] = []
    nonisolated(unsafe) static var telemetryHeaders: [String?] = []
    nonisolated(unsafe) static var userAgents: [String?] = []

    static func reset() {
        scripted = []
        served = 0
        requestedHosts = []
        telemetryHeaders = []
        userAgents = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requestedHosts.append(request.url?.host ?? "")
        Self.telemetryHeaders.append(request.value(forHTTPHeaderField: "x-tr-client"))
        Self.userAgents.append(request.value(forHTTPHeaderField: "user-agent"))
        let index = Self.served
        Self.served += 1
        let outcome: Outcome = index < Self.scripted.count
            ? Self.scripted[index]
            : .failure(URLError(.unknown))
        switch outcome {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://invalid.local")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
