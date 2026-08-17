import Foundation
import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Credential scoping on absolute-URL fetches: the SDK-attached credential
// headers (`authorization`, `x-trustedrouter-workspace`, `idempotency-key`)
// are sent only to the configured and well-known TrustedRouter API/control
// origins, and the status fetch carries none of them anywhere — mirroring
// trusted-router-py, where `status()` is a bare single-shot get on the raw
// HTTP client and those headers exist only inside `_request`, which never
// sees an absolute URL. Client-wide non-credential defaults still ride along
// everywhere; scoping covers the three names the SDK attaches itself.
//
// Wire tests ride the real request path through `MockURLProtocol`
// (TrustedRouterEndpointTests.swift). Where two mechanisms would mask each
// other — the host allowlist already denies the status host, so it cannot
// also witness the scheme check or the bare status fetcher — the test that
// isolates each mechanism is called out in a comment.

/// Attempt counter for the mock handler, which is invoked off the test's own
/// task.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class CredentialScopeTests: XCTestCase {
    var router: TrustedRouter!
    var session: URLSession!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)

        router = try TrustedRouter(options: TrustedRouterOptions(
            apiKey: "test_key",
            baseUrl: "https://inference.test/v1",
            controlBaseURL: "https://control.test/v1",
            urlSession: session,
            workspaceId: "test_workspace"
        ))
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
    }

    private static func ok(_ request: URLRequest, body: String = "{}") -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (response, body.data(using: .utf8)!)
    }

    // MARK: - (a) Foreign absolute URLs carry no credential headers

    func testForeignAbsoluteURLCarriesNoCredentialHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://evil.example/collect.json")
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            XCTAssertNil(request.value(forHTTPHeaderField: "idempotency-key"))
            // Non-credential headers still ride along.
            XCTAssertNotNil(request.value(forHTTPHeaderField: "user-agent"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-custom"), "yes")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://evil.example/collect.json",
            options: PerCallOptions(
                extraHeaders: ["x-custom": "yes"],
                // Even an explicitly supplied key stays off foreign origins.
                idempotencyKey: "explicit-idem-key"
            )
        )
    }

    func testUserinfoConfusionDoesNotLeakCredentials() async throws {
        // The connect host is `evil.example`; the TrustedRouter hostname is
        // only userinfo. No credentials may be attached.
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://api.trustedrouter.com@evil.example/x"
        )
    }

    func testNonDefaultPortOnTrustedRouterHostIsNotTrusted() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://api.trustedrouter.com:8443/v1/models"
        )
    }

    func testTrailingDotHostIsNotTrusted() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://api.trustedrouter.com./v1/models"
        )
    }

    // MARK: - (b) The status fetch is credential-free everywhere

    func testDefaultStatusFetchSendsNoCredentialHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, TrustedRouterConstants.defaultStatusURL)
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            XCTAssertNil(request.value(forHTTPHeaderField: "idempotency-key"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "user-agent"))
            return Self.ok(request, body: "{\"status\": \"ok\"}")
        }
        let dict = try await router.status()
        XCTAssertEqual(dict["status"] as? String, "ok")
    }

    func testCustomStatusURLSendsNoCredentialHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://status.example/custom.json")
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request, body: "{\"status\": \"ok\"}")
        }
        let dict = try await router.status(url: "https://status.example/custom.json")
        XCTAssertEqual(dict["status"] as? String, "ok")
    }

    /// The status request is assembled through `buildHeaders`, so client-wide
    /// non-credential defaults and the standard user-agent still apply — only
    /// the credential names are withheld. Without this, reverting the status
    /// fetch to a hand-rolled request carrying a bare version string would go
    /// undetected.
    func testStatusFetchKeepsClientWideNonCredentialDefaults() async throws {
        let router = try TrustedRouter(options: TrustedRouterOptions(
            apiKey: "test_key",
            urlSession: session,
            headers: ["x-trace-id": "keep-me"],
            workspaceId: "test_workspace"
        ))
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-trace-id"), "keep-me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "user-agent"), TrustedRouter.userAgent)
            return Self.ok(request, body: "{\"status\": \"ok\"}")
        }
        let dict = try await router.status()
        XCTAssertEqual(dict["status"] as? String, "ok")
    }

    /// The status fetch is single-shot, mirroring py's `self._client.get(url)`.
    /// This is the assertion that distinguishes the bare fetcher from
    /// `request<T>`, whose retry loop re-sends a 429: the host allowlist alone
    /// already makes the status host credential-free, so without this the two
    /// mechanisms mask each other.
    func testStatusFetchIsSingleShot() async {
        let counter = Counter()
        MockURLProtocol.requestHandler = { request in
            counter.increment()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await router.status()
            XCTFail("Expected a TrustedRouterError for a 429 status page")
        } catch {
            // Classification is asserted separately below.
        }
        XCTAssertEqual(counter.value, 1)
    }

    /// Regression guard, not fix coverage: taking `status()` off the shared
    /// `request<T>` path must not downgrade the public error taxonomy. It
    /// routes failures through the same classifier, so a typed case, the
    /// server's message, and `Retry-After` all still surface.
    func testStatusFetchPreservesTheTypedErrorTaxonomy() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["retry-after": "7"]
            )!
            let body = "{\"error\": {\"message\": \"slow down\"}}".data(using: .utf8)!
            return (response, body)
        }
        do {
            _ = try await router.status()
            XCTFail("Expected a TrustedRouterError for a 429 status page")
        } catch let error as TrustedRouterError {
            if case let .rateLimit(statusCode, message, _, retryAfterSeconds) = error {
                XCTAssertEqual(statusCode, 429)
                XCTAssertEqual(message, "slow down")
                XCTAssertEqual(retryAfterSeconds, 7)
            } else {
                XCTFail("Expected .rateLimit, got \(error)")
            }
        } catch {
            XCTFail("Expected TrustedRouterError, got \(error)")
        }
    }

    // MARK: - (c) In-scope origins: the API/control planes, not the
    // public-document hosts. This is the pinned implementation choice.

    func testTrustedRouterAPIHostAbsoluteURLKeepsCredentialHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"), "test_workspace")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: TrustedRouterConstants.defaultAPIBaseURL + "/models"
        )
    }

    func testPublicDocumentHostsAreNotCredentialledEvenViaRequest() async throws {
        // The status and trust-release hosts serve unauthenticated JSON and
        // nothing in the SDK authenticates to them, so they are deliberately
        // out of scope: a hand-written absolute-URL request to either cannot
        // carry the account's bearer. This is defence in depth behind the
        // credential-free fetchers themselves.
        for absoluteURL in [
            TrustedRouterConstants.defaultStatusURL,
            TrustedRouterConstants.defaultTrustReleaseURL
        ] {
            MockURLProtocol.requestHandler = { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "authorization"), absoluteURL)
                XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"), absoluteURL)
                return Self.ok(request)
            }
            let _: Data = try await router.request(method: "GET", path: absoluteURL)
        }
    }

    func testHostMatchingIsCaseInsensitive() async throws {
        // Hostnames are case-insensitive on the wire: an uppercase spelling
        // of a TrustedRouter origin is the same origin.
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "HTTPS://API.TRUSTEDROUTER.COM/v1/models"
        )
    }

    func testExplicitDefaultPortMatchesTrustedRouterOrigin() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://api.trustedrouter.com:443/v1/models"
        )
    }

    // MARK: - (d) Relative API-plane requests are unchanged

    func testRelativeControlPlaneRequestStillCarriesCredentials() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://control.test/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"), "test_workspace")
            return Self.ok(request, body: "{\"balance\": 1.0, \"currency\": \"USD\"}")
        }
        let credits = try await router.credits()
        XCTAssertEqual(credits.balance, 1.0)
    }

    func testRelativeInferenceMutationStillCarriesCredentialsAndMintsIdempotencyKey() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://inference.test/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"), "test_workspace")
            XCTAssertEqual(request.value(forHTTPHeaderField: "idempotency-key")?.hasPrefix("tr-req-"), true)
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "POST",
            path: "/chat/completions",
            body: ["model": "trustedrouter/auto"]
        )
    }

    // MARK: - (e) The scheme matters

    func testHTTPSchemeOnTrustedRouterHostnameIsNotTrusted() async throws {
        // Every TrustedRouter endpoint constant is https; a plaintext
        // downgrade of the same hostname must not receive the bearer token.
        // Uses the API host on purpose: on a host that is out of scope anyway
        // (status, trust) the allowlist would mask the scheme check.
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "http://api.trustedrouter.com/v1/models"
        )
    }

    func testHTTPSchemeSpellingTheHTTPSPortIsStillNotTrusted() async throws {
        // The scheme is compared directly rather than being implied by the
        // effective port: spelling out :443 on an http URL must not smuggle a
        // plaintext request into scope. (This case is what distinguishes the
        // scheme check from the port check — a mutant dropping the scheme
        // field survives every other assertion in this file.)
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "http://api.trustedrouter.com:443/v1/models"
        )
    }

    // MARK: - Client-wide default headers are scoped too

    func testClientWideDefaultCredentialHeadersAreWithheldFromForeignOrigins() async throws {
        // A client-wide `headers:` default is configured once for the
        // client's own hosts; it is not authorization to credential whatever
        // origin a caller-supplied absolute URL names. Non-credential
        // defaults (tracing, proxy routing) still ride along.
        let router = try TrustedRouter(options: TrustedRouterOptions(
            apiKey: "test_key",
            baseUrl: "https://inference.test/v1",
            urlSession: session,
            headers: [
                // Mixed casing on purpose: HTTP field names are
                // case-insensitive, so the strip must be too.
                "Authorization": "Bearer configured_default",
                "X-TrustedRouter-Workspace": "configured_workspace",
                "Idempotency-Key": "configured_key",
                "x-trace-id": "keep-me"
            ]
        ))
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            // Covers `idempotency-key`'s membership in the strip set, which
            // the per-call assertions cannot witness: those are stopped by the
            // separate SDK-attached guard instead.
            XCTAssertNil(request.value(forHTTPHeaderField: "idempotency-key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-trace-id"), "keep-me")
            return Self.ok(request)
        }
        let _: Data = try await router.request(method: "GET", path: "https://evil.example/x")
    }

    func testClientWideDefaultCredentialHeadersSurviveOnInScopeOrigins() async throws {
        let router = try TrustedRouter(options: TrustedRouterOptions(
            baseUrl: "https://inference.test/v1",
            urlSession: session,
            headers: ["Authorization": "Bearer configured_default"]
        ))
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer configured_default")
            return Self.ok(request)
        }
        let _: Data = try await router.request(method: "GET", path: "/models")
    }

    func testExplicitPerCallHeaderIsNeverWithheld() async throws {
        // The documented escape hatch: a header the caller names at the call
        // site is the caller's own choice, on any origin.
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer caller_supplied")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://private-gateway.example/v1/jobs",
            options: PerCallOptions(extraHeaders: ["authorization": "Bearer caller_supplied"])
        )
    }

    // MARK: - Predicate unit coverage (no networking)

    func testCredentialHostAllowlistPredicate() throws {
        let allowlist = router.credentialHostAllowlist

        func allows(_ urlString: String) -> Bool {
            guard let url = URL(string: urlString) else { return false }
            return allowlist.allowsCredentials(for: url)
        }

        // The well-known API and control planes are in scope.
        XCTAssertTrue(allows(TrustedRouterConstants.defaultAPIBaseURL))
        XCTAssertTrue(allows(TrustedRouterConstants.defaultControlBaseURL))
        // The public-document hosts are deliberately NOT.
        XCTAssertFalse(allows(TrustedRouterConstants.defaultStatusURL))
        XCTAssertFalse(allows(TrustedRouterConstants.defaultTrustReleaseURL))
        for alias in TrustedRouterConstants.aliasAPIBaseURLs {
            XCTAssertTrue(allows(alias), alias)
        }
        for region in TrustedRouterConstants.regionBaseURLs {
            XCTAssertTrue(allows(region), region)
        }
        XCTAssertTrue(allows("https://api.trustedrouter.com/any/path?query=1"))

        // The instance's own configured bases.
        XCTAssertTrue(allows("https://inference.test/v1/chat/completions"))
        XCTAssertTrue(allows("https://control.test/v1/credits"))

        // Everything else fails closed.
        XCTAssertFalse(allows("https://evil.example/"))
        XCTAssertFalse(allows("http://api.trustedrouter.com/v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com:8443/v1"))
        XCTAssertFalse(allows("http://api.trustedrouter.com:443/v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com:80/v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com./v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com.evil.example/v1"))
        XCTAssertFalse(allows("https://evil.example/api.trustedrouter.com/v1"))
        XCTAssertFalse(allows("file:///etc/passwd"))
        XCTAssertFalse(allows("ftp://api.trustedrouter.com/v1"))

        // Userinfo is refused outright, so no Foundation-version disagreement
        // about which component is the authority can grant credentials. The
        // first two would also be denied by the host comparison alone; the
        // `user@api.trustedrouter.com` cases are the ones that isolate this
        // guard, since their host IS an in-scope host.
        XCTAssertFalse(allows("https://api.trustedrouter.com@evil.example/"))
        XCTAssertFalse(allows("https://api.trustedrouter.com:x@evil.example/"))
        XCTAssertFalse(allows("https://user@api.trustedrouter.com/v1"))
        XCTAssertFalse(allows("https://user:pass@api.trustedrouter.com/v1"))
        XCTAssertFalse(allows("https://user@api.trustedrouter.com@evil.example/v1"))

        // Malformed and exotic authorities fail closed. These pin the
        // predicate's behaviour on the inputs where Foundation versions are
        // most likely to differ; CI only runs modern macOS and Linux, so the
        // value here is the fail-closed default, not parser equivalence.
        XCTAssertFalse(allows("https://[::1]/v1"))
        XCTAssertFalse(allows("https://[::1]:443/v1"))
        XCTAssertFalse(allows("https:///v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com:99999/v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com\t/v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com\n/v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com /v1"))
        XCTAssertFalse(allows("https://api.trustedrouter.com\\@evil.example/v1"))
        XCTAssertFalse(allows("https://%61pi.trustedrouter.com.evil.example/v1"))
    }
}
