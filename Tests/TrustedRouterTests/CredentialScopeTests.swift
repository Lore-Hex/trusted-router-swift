import Foundation
import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Credential scoping on absolute-URL fetches: the SDK-attached credential
// headers (`authorization`, `x-trustedrouter-workspace`, `idempotency-key`)
// are sent only to known TrustedRouter origins, and the status fetch is
// credential-free everywhere — mirroring trusted-router-py, where `status()`
// rides the raw HTTP client and the credential headers exist only inside
// `_request`, which never sees an absolute URL. Wire tests ride the real
// request path through `MockURLProtocol` (TrustedRouterEndpointTests.swift).

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
            path: "https://status.trustedrouter.com./status.json"
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

    func testStatusFetchThrowsTypedErrorOnHTTPFailure() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await router.status()
            XCTFail("Expected a TrustedRouterError for a 503 status page")
        } catch let error as TrustedRouterError {
            if case let .generic(statusCode, _, _) = error {
                XCTAssertEqual(statusCode, 503)
            } else {
                XCTFail("Expected .generic, got \(error)")
            }
        } catch {
            XCTFail("Expected TrustedRouterError, got \(error)")
        }
    }

    // MARK: - (c) Known TrustedRouter origins keep credentials on absolute URLs

    func testTrustedRouterHostAbsoluteURLKeepsCredentialHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"), "test_workspace")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: TrustedRouterConstants.defaultTrustReleaseURL
        )
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
            path: "HTTPS://STATUS.TRUSTEDROUTER.COM/status.json"
        )
    }

    func testExplicitDefaultPortMatchesTrustedRouterOrigin() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer test_key")
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "https://status.trustedrouter.com:443/status.json"
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
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"))
            return Self.ok(request)
        }
        let _: Data = try await router.request(
            method: "GET",
            path: "http://status.trustedrouter.com/status.json"
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
            path: "http://status.trustedrouter.com:443/status.json"
        )
    }

    // MARK: - Predicate unit coverage (no networking)

    func testCredentialHostAllowlistPredicate() throws {
        let allowlist = router.credentialHostAllowlist

        func allows(_ urlString: String) -> Bool {
            guard let url = URL(string: urlString) else { return false }
            return allowlist.allowsCredentials(for: url)
        }

        // Known TrustedRouter origins, from the constants.
        XCTAssertTrue(allows(TrustedRouterConstants.defaultAPIBaseURL))
        XCTAssertTrue(allows(TrustedRouterConstants.defaultControlBaseURL))
        XCTAssertTrue(allows(TrustedRouterConstants.defaultStatusURL))
        XCTAssertTrue(allows(TrustedRouterConstants.defaultTrustReleaseURL))
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
        XCTAssertFalse(allows("https://api.trustedrouter.com@evil.example/"))
        XCTAssertFalse(allows("https://status.trustedrouter.com./status.json"))
        XCTAssertFalse(allows("https://api.trustedrouter.com.evil.example/v1"))
        XCTAssertFalse(allows("file:///etc/passwd"))
    }
}
