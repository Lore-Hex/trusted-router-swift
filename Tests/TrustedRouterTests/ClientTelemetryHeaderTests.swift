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

    /// The doc's §3.2 example string, byte for byte, from the real recorder
    /// with an injected clock. NOTE the parity ruling: the doc's prose
    /// ("retry after a connect timeout") contradicts the Python reference —
    /// a plain connect timeout is outcome `timeout` there, so the engine
    /// emits `po=timeout;pc=connect_timeout` for it (asserted in
    /// testTransportTimeoutRetryCarriesPreviousAttemptContext, and the doc
    /// carries the bug per its own "the modules win" header). The doc's
    /// literal `po=transport_error;pc=connect_timeout` combination is
    /// reachable only when the timeout is buried under a non-timeout
    /// wrapper, which is how this vector constructs it.
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

    func testVerdictForcedRetryAfterOkCarriesPoNone() async throws {
        // x-should-retry: true on a 2xx forces a retry (engine invariant 4),
        // so the previous attempt's outcome really is `ok` — which is NOT in
        // §3.2's po vocabulary. The header must say po=none, never po=ok
        // (the enclave would drop the whole header for it).
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [
            .labelled(200, "{}", ["x-should-retry": "true"]),
            .response(200, "{}"),
        ]
        let router = try makeRouter(maxRetries: 1)

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders.count, 2)
        assertMatches(
            TelemetryCaptureProtocol.telemetryHeaders.last ?? nil,
            "^v=1;a=1;po=none;pc=none;ph=apex;pm=[0-9]{1,7};sm=[0-9]{1,7};s=0;fo=0$"
        )
    }

    func testPreviousOkMapsToPoNoneInTheRecorder() {
        var clock = 0.0
        let recorder = RequestRecorder(streaming: false, now: { clock })
        recorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        clock = 1.0005
        recorder.onResponse(statusCode: 200)
        clock = 2.0005
        recorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        XCTAssertEqual(
            recorder.headerValue(),
            "v=1;a=1;po=none;pc=none;ph=apex;pm=1000;sm=2000;s=0;fo=0"
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

    func testRawRequestNeverEmitsTelemetryAndStripsForgedValues() async throws {
        // rawRequest is single-shot by contract and reserved as the beacon
        // attach point (§6.1) — it must not grow a header in this PR, and a
        // forged reserved header must not ride it either.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}"), .response(200, "{}")]
        let router = try makeRouter(telemetry: true)

        _ = try await router.rawRequest(method: "GET", path: "/x")
        _ = try await router.rawRequest(
            method: "GET",
            path: "/x",
            options: PerCallOptions(extraHeaders: ["X-Tr-Client": "v=1;a=5;s=1"])
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil, nil])
    }

    func testAbsoluteURLFetchSendsNoHeader() async throws {
        // An absolute URL never resolves against the inference candidate
        // list, so it gets no recorder even on the inference plane.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter(telemetry: true)

        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: TrustedRouterConstants.defaultStatusURL
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil])
        XCTAssertEqual(TelemetryCaptureProtocol.requestedHosts, ["status.trustedrouter.com"])
    }

    func testActiveRecorderOwnsTheHeaderAgainstForgedValues() async throws {
        // A caller-supplied x-tr-client (any casing) must never ride along
        // with an active recorder — the SDK's value replaces it outright.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter(telemetry: true)

        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: "/x",
            options: PerCallOptions(extraHeaders: ["X-TR-Client": "v=1;a=7;s=1"])
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, ["v=1;a=0;s=0"])
    }

    func testReservedHeaderIsStrippedEvenWhenTelemetryIsOff() async throws {
        // x-tr-client is SDK-reserved on every path (ruled stronger than the
        // py reference, whose stripping is recorder-scoped): an opted-out
        // client must not let a caller-supplied value ride along, in any
        // casing — otherwise opt-out, the control-plane exclusion, and the
        // custom-base exclusion could all be bypassed from the header layer.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}"), .response(200, "{}")]
        let router = try makeRouter(telemetry: false)

        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: "/x",
            options: PerCallOptions(extraHeaders: ["x-tr-client": "v=1;a=3;s=1"])
        )
        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: "/x",
            headers: ["X-TR-CLIENT": "v=1;a=4;s=0"]
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil, nil])
    }

    func testOutOfScopeAbsoluteURLStripsForgedReservedHeaders() async throws {
        // The credential-scoping merge hazard, pinned. Credential scoping
        // (Transport/CredentialScope.swift) returns EARLY from buildHeaders
        // for an origin outside the TrustedRouter allowlist, so the reserved
        // header's strip has to sit above that return. If it is ever moved
        // below it, this is the one path that would still carry a forged
        // x-tr-client — to a foreign host, which is the worst place to leak
        // a retry history to. Every casing, both header layers.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}"), .response(200, "{}")]
        let router = try makeRouter(telemetry: true)

        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: "https://evil.example/collect.json",
            options: PerCallOptions(extraHeaders: ["X-Tr-Client": "v=1;a=9;s=1"])
        )
        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: "https://evil.example/collect.json",
            headers: ["x-TR-client": "v=1;a=8;s=0"]
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil, nil])
        XCTAssertEqual(TelemetryCaptureProtocol.requestedHosts,
                       ["evil.example", "evil.example"])
    }

    func testClientWideDefaultReservedHeaderIsStripped() async throws {
        // The third merge layer: a forged value configured once on the client
        // rather than per call. Covered separately because `defaultHeaders` is
        // applied before the per-call layers and by a different loop.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}"), .response(200, "{}")]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryCaptureProtocol.self]
        let offRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            headers: ["X-Tr-Client": "v=1;a=6;s=1"],
            telemetry: false
        ))
        let _: EmptyResponse = try await offRouter.request(method: "GET", path: "/x")
        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil])

        // With telemetry on, the recorder's own value replaces it rather than
        // appending a second case-variant.
        let onRouter = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            headers: ["X-TR-CLIENT": "v=1;a=6;s=1"],
            telemetry: true
        ))
        let _: EmptyResponse = try await onRouter.request(method: "GET", path: "/x")
        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil, "v=1;a=0;s=0"])
    }

    func testStreamRequestStripsForgedReservedHeaders() async throws {
        // The streaming entry point takes its own route into the engine, so
        // the strip is asserted on it directly and not by proxy.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "data: [DONE]\n\n")]
        let router = try makeRouter(telemetry: false)

        _ = try await router.rawStreamRequest(
            method: "POST",
            path: "/chat/completions",
            body: Data("{}".utf8),
            options: PerCallOptions(extraHeaders: ["X-Tr-Client": "v=1;a=4;s=1"])
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil])
    }

    func testActiveRecorderValueOverridesAnInjectedSessionDefault() async throws {
        // KNOWN BOUNDARY, pinned rather than papered over.
        // `URLSessionConfiguration.httpAdditionalHeaders` is merged by the URL
        // loading system AFTER the request leaves buildHeaders, for exactly
        // the fields the request does not set — so a caller who configures
        // their own session with `x-tr-client` does put it on the wire on the
        // paths where the SDK sets nothing (opted out, control plane, custom
        // base, absolute URL, rawRequest). The SDK cannot strip it there: the
        // only suppressing value is an empty one, which would mean emitting a
        // bare `x-tr-client:` on every excluded request and breaking §6.3
        // opt-out to close a hole only the caller's own transport can open.
        // See the boundary note in buildHeaders.
        //
        // What IS guaranteed, and asserted here: on a described attempt the
        // SDK's request-level value wins outright, so the header the enclave
        // attributes to this SDK can never be a caller's forgery.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TelemetryCaptureProtocol.self]
        config.httpAdditionalHeaders = ["x-tr-client": "v=1;a=77;forged"]
        let router = try TrustedRouter(options: .init(
            apiKey: "test_key",
            urlSession: URLSession(configuration: config),
            telemetry: true
        ))

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, ["v=1;a=0;s=0"],
                       "the recorder's value must win over a session default")
    }

    func testControlPlaneCallStripsForgedReservedHeaders() async throws {
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [.response(200, "{}")]
        let router = try makeRouter(telemetry: true)

        let _: EmptyResponse = try await router.request(
            method: "GET",
            path: "/auth/session",
            options: PerCallOptions(extraHeaders: ["X-Tr-Client": "v=1;a=2;s=1"]),
            plane: .control
        )

        XCTAssertEqual(TelemetryCaptureProtocol.telemetryHeaders, [nil])
    }

    func testNoTelemetryHTTPCallsExist() async throws {
        // §6.4: the SDK's own fake transport sees zero /client-events calls.
        // The beacon channel is deliberately absent from this PR; this pins
        // that no code path grew a telemetry POST.
        TelemetryCaptureProtocol.reset()
        TelemetryCaptureProtocol.scripted = [
            .failure(URLError(.timedOut)),
            .response(200, "{}"),
        ]
        let router = try makeRouter(maxRetries: 1)

        let _: EmptyResponse = try await router.request(method: "GET", path: "/x")

        XCTAssertTrue(
            TelemetryCaptureProtocol.requestedPaths.allSatisfy { !$0.contains("client-events") },
            "no beacon traffic may exist in the header-only PR: \(TelemetryCaptureProtocol.requestedPaths)"
        )
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
        // Bare .cannotConnectToHost is an UNPROVEN connect failure:
        // connect_refused is reserved for a proven ECONNREFUSED (below),
        // matching go/js/py so per-class distributions compare across SDKs.
        XCTAssertEqual(classify(URLError(.cannotConnectToHost)), "connect_error")
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
        XCTAssertEqual(
            classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))),
            "connect_error"
        )
        XCTAssertEqual(
            classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))),
            "connect_timeout"
        )

        XCTAssertEqual(
            classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENETUNREACH))),
            "connect_error"
        )

        // POSIX detail outranks the coarse URLError bucket: the same
        // .cannotConnectToHost is connect_refused bare, but connect_error
        // when the surviving errno says the host was unreachable.
        let unreachable = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH)
                ),
            ]
        )
        XCTAssertEqual(classify(unreachable), "connect_error")
        let refused = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)
                ),
            ]
        )
        XCTAssertEqual(classify(refused), "connect_refused")
        // ...and `reset` when the surviving errno says the connection was
        // reset mid-connect. py's order is ConnectionRefusedError, then
        // ConnectionResetError, then httpx.ConnectError, so a reset under a
        // connect error is `reset` there too; testing the coarse
        // `.cannotConnectToHost` bucket before this one would report
        // connect_error and put `pc` out of step with every other SDK.
        let resetMidConnect = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)
                ),
            ]
        )
        XCTAssertEqual(classify(resetMidConnect), "reset")
        // Refusal still outranks reset when both errnos somehow appear, and
        // the unreachable pair still loses to a proven reset — pinning the
        // whole refused > reset > unreachable > coarse-bucket order, not just
        // the one pair the fix moved.
        let resetUnderUnreachable = NSError(
            domain: NSURLErrorDomain,
            code: URLError.cannotConnectToHost.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ECONNRESET),
                    userInfo: [
                        NSUnderlyingErrorKey: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH)
                        ),
                    ]
                ),
            ]
        )
        XCTAssertEqual(classify(resetUnderUnreachable), "reset")

        // The class survives one level of wrapping — the underlying-error
        // chain is walked exactly like py's __cause__/__context__ chain.
        let wrapped = NSError(
            domain: "Wrapper",
            code: 7,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost) as NSError]
        )
        XCTAssertEqual(classify(wrapped), "dns")
        XCTAssertEqual(classify(NSError(domain: "Opaque", code: 1)), "unknown")

        // Chain walking is depth-capped and never loops: a deep chain still
        // classifies within the first six errors, and one past the cap does
        // not (falls to unknown rather than walking forever).
        func nest(_ error: NSError, depth: Int) -> NSError {
            var current = error
            for level in 0..<depth {
                current = NSError(
                    domain: "Wrap\(level)",
                    code: level,
                    userInfo: [NSUnderlyingErrorKey: current]
                )
            }
            return current
        }
        let posixReset = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        XCTAssertEqual(classify(nest(posixReset, depth: 5)), "reset",
                       "five wrappers plus the leaf is exactly the depth cap")
        XCTAssertEqual(classify(nest(posixReset, depth: 6)), "unknown",
                       "beyond the six-error cap the walk stops, mirroring py")
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

    func testAttemptIndexPastTheContractCeilingSendsNothing() {
        var clock = 0.0
        let recorder = RequestRecorder(streaming: false, now: { clock })
        for _ in 0..<100 {
            recorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
            clock += 1.0
            recorder.onTransportError(URLError(.cannotConnectToHost))
        }
        recorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        XCTAssertNil(recorder.headerValue(),
                     "a=100 is outside the contract's 0..99; send nothing rather than a droppable header")
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
        // The grammar makes the runtime token optional, so matching it alone
        // would also pass if the runtime were dropped again — which is the
        // regression this PR exists to fix. Pin that the token is present and
        // that the version really is the SDK's, not a placeholder.
        XCTAssertNotNil(
            agent.range(
                of: "^trusted-router-swift/\(semver) [a-z]{1,10}/[0-9A-Za-z.+-]{1,24}$",
                options: .regularExpression
            ),
            "the runtime token must be present, not just grammatical: \(agent)"
        )
        XCTAssertTrue(
            agent.hasPrefix("trusted-router-swift/\(TrustedRouterConstants.version) "),
            "the version must be the SDK's own: \(agent)"
        )
    }
}

/// Scripted transport fake for the telemetry tests: serves each entry once,
/// recording the host, `x-tr-client`, and `user-agent` of every request the
/// engine actually put on the wire.
final class TelemetryCaptureProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case response(Int, String)
        case labelled(Int, String, [String: String])
        case failure(URLError)
    }

    nonisolated(unsafe) static var scripted: [Outcome] = []
    nonisolated(unsafe) static var served = 0
    nonisolated(unsafe) static var requestedHosts: [String] = []
    nonisolated(unsafe) static var requestedPaths: [String] = []
    nonisolated(unsafe) static var telemetryHeaders: [String?] = []
    nonisolated(unsafe) static var userAgents: [String?] = []

    static func reset() {
        scripted = []
        served = 0
        requestedHosts = []
        requestedPaths = []
        telemetryHeaders = []
        userAgents = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requestedHosts.append(request.url?.host ?? "")
        Self.requestedPaths.append(request.url?.path ?? "")
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
            respond(status: status, body: body, extraHeaders: [:])
        case .labelled(let status, let body, let extraHeaders):
            respond(status: status, body: body, extraHeaders: extraHeaders)
        }
    }

    private func respond(status: Int, body: String, extraHeaders: [String: String]) {
        var fields = ["Content-Type": "application/json"]
        for (name, value) in extraHeaders { fields[name] = value }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.local")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
