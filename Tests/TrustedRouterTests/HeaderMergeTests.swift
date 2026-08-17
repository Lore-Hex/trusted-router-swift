import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP header names are case-insensitive; `[String: String]` is not. Before
/// the case-insensitive merge, a caller-supplied `User-Agent` or
/// `Authorization` in a different casing than the SDK's lowercase keys left
/// BOTH entries in the merged dictionary, and because `URLRequest`'s header
/// store is case-insensitive, whichever entry dictionary iteration applied
/// last silently won — a nondeterministic override. These tests pin the
/// deterministic layer precedence:
/// built-ins < defaultHeaders < per-call headers < extraHeaders < computed,
/// and the one exception: a caller-supplied authorization header (any layer,
/// any casing) suppresses the apiKey-derived one.
final class HeaderMergeTests: XCTestCase {

    private func makeRouter(
        apiKey: String? = "test_key",
        headers: [String: String] = [:],
        workspaceId: String? = nil
    ) throws -> TrustedRouter {
        try TrustedRouter(options: .init(
            apiKey: apiKey,
            urlSession: URLSession(configuration: .ephemeral),
            headers: headers,
            workspaceId: workspaceId
        ))
    }

    /// All keys in `dict` that name the same header as `name`.
    private func variants(of name: String, in dict: [String: String]) -> [String] {
        dict.keys.filter { $0.lowercased() == name.lowercased() }.sorted()
    }

    private func value(of name: String, in dict: [String: String]) -> String? {
        dict.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    private func request(
        from router: TrustedRouter,
        headers: [String: String]? = nil,
        options: PerCallOptions = PerCallOptions(),
        body: Data? = nil
    ) throws -> URLRequest {
        router.buildURLRequest(
            method: "POST",
            url: try XCTUnwrap(URL(string: "https://api.trustedrouter.com/v1/x")),
            headers: headers,
            options: options,
            body: body
        )
    }

    // MARK: - Layer precedence across casings

    func testDefaultHeadersOverrideTheBuiltInUserAgentAcrossCasing() throws {
        let router = try makeRouter(headers: ["USER-AGENT": "custom-agent/1"])
        let merged = router.buildHeaders()

        XCTAssertEqual(variants(of: "user-agent", in: merged), ["USER-AGENT"],
                       "exactly one canonical entry must survive")
        XCTAssertEqual(value(of: "user-agent", in: merged), "custom-agent/1")

        let request = try request(from: router)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "custom-agent/1")
    }

    func testPerCallHeadersOverrideDefaultHeadersAcrossCasing() throws {
        let router = try makeRouter(headers: ["X-Env": "default-layer"])
        let merged = router.buildHeaders(headers: ["x-env": "per-call-layer"])

        XCTAssertEqual(variants(of: "x-env", in: merged), ["x-env"])
        XCTAssertEqual(value(of: "x-env", in: merged), "per-call-layer")
    }

    func testExtraHeadersOverridePerCallHeadersAcrossCasing() throws {
        let router = try makeRouter()
        let merged = router.buildHeaders(
            headers: ["X-Env": "per-call-layer"],
            extraHeaders: ["X-ENV": "extra-layer"]
        )

        XCTAssertEqual(variants(of: "x-env", in: merged), ["X-ENV"])
        XCTAssertEqual(value(of: "x-env", in: merged), "extra-layer")

        let request = try request(
            from: router,
            headers: ["X-Env": "per-call-layer"],
            options: PerCallOptions(extraHeaders: ["X-ENV": "extra-layer"])
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-env"), "extra-layer")
    }

    // MARK: - The authorization exception

    func testCallerAuthorizationInDefaultHeadersBeatsTheAPIKeyAcrossCasing() throws {
        let router = try makeRouter(headers: ["AUTHORIZATION": "Bearer caller-default"])
        let merged = router.buildHeaders()

        XCTAssertEqual(variants(of: "authorization", in: merged), ["AUTHORIZATION"])
        XCTAssertEqual(value(of: "authorization", in: merged), "Bearer caller-default")
    }

    func testCallerAuthorizationInPerCallLayersBeatsTheAPIKeyAcrossCasing() throws {
        let router = try makeRouter()
        let merged = router.buildHeaders(headers: ["Authorization": "Bearer caller-percall"])
        XCTAssertEqual(variants(of: "authorization", in: merged), ["Authorization"])
        XCTAssertEqual(value(of: "authorization", in: merged), "Bearer caller-percall")

        let viaExtra = router.buildHeaders(extraHeaders: ["Authorization": "Bearer caller-extra"])
        XCTAssertEqual(value(of: "authorization", in: viaExtra), "Bearer caller-extra")

        let request = try request(
            from: router,
            options: PerCallOptions(extraHeaders: ["Authorization": "Bearer caller-extra"])
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer caller-extra")
    }

    func testAPIKeyFillsInWhenNoCallerAuthorizationExists() throws {
        let router = try makeRouter()
        let merged = router.buildHeaders()
        XCTAssertEqual(variants(of: "authorization", in: merged), ["authorization"])
        XCTAssertEqual(value(of: "authorization", in: merged), "Bearer test_key")
    }

    func testPerCallAPIKeyOverrideStillRespectsCallerAuthorization() throws {
        let router = try makeRouter()
        let merged = router.buildHeaders(
            headers: ["AUTHORIZATION": "Bearer caller"],
            apiKey: "per_call_key"
        )
        XCTAssertEqual(value(of: "authorization", in: merged), "Bearer caller")
    }

    // MARK: - Computed headers are the last layer

    func testComputedHeadersDeterministicallyOverrideCallerCaseVariants() throws {
        let router = try makeRouter()
        let merged = router.buildHeaders(
            extraHeaders: [
                "Idempotency-Key": "caller-key",
                "X-TrustedRouter-Workspace": "caller-ws",
            ],
            idempotencyKey: "opt-key",
            workspaceId: "opt-ws"
        )

        XCTAssertEqual(variants(of: "idempotency-key", in: merged), ["idempotency-key"])
        XCTAssertEqual(value(of: "idempotency-key", in: merged), "opt-key")
        XCTAssertEqual(variants(of: "x-trustedrouter-workspace", in: merged),
                       ["x-trustedrouter-workspace"])
        XCTAssertEqual(value(of: "x-trustedrouter-workspace", in: merged), "opt-ws")
    }

    // MARK: - Determinism under collisions everywhere

    func testCaseCollisionsAcrossEveryLayerAreDeterministic() throws {
        // Under the old case-sensitive merge this dictionary ended up with
        // three case-variants of the same header and the wire value depended
        // on dictionary iteration order. Repeated fresh constructions guard
        // against a lucky hash seed masking a regression.
        for _ in 0..<50 {
            let router = try makeRouter(headers: ["X-Case-Test": "default-layer"])
            let merged = router.buildHeaders(
                headers: ["X-CASE-TEST": "per-call-layer"],
                extraHeaders: ["x-case-test": "extra-layer"]
            )
            XCTAssertEqual(variants(of: "x-case-test", in: merged), ["x-case-test"],
                           "exactly one case-variant may survive the merge")
            XCTAssertEqual(value(of: "x-case-test", in: merged), "extra-layer")

            let request = try request(
                from: router,
                headers: ["X-CASE-TEST": "per-call-layer"],
                options: PerCallOptions(extraHeaders: ["x-case-test": "extra-layer"])
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Case-Test"), "extra-layer")
        }
    }

    func testContentTypeDefaultRespectsCallerCasing() throws {
        let router = try makeRouter()
        let plain = try request(from: router, body: Data("{}".utf8))
        XCTAssertEqual(plain.value(forHTTPHeaderField: "Content-Type"), "application/json",
                       "the default still applies when the caller sets nothing")

        let custom = try request(
            from: router,
            options: PerCallOptions(extraHeaders: ["CONTENT-TYPE": "text/plain"]),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(custom.value(forHTTPHeaderField: "Content-Type"), "text/plain",
                       "a caller content type in any casing suppresses the default")
    }
}
