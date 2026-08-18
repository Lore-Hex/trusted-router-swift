import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DeepConformanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DeepConformanceProtocol.reset()
    }

    func testHighLevelChatRetriesWithOneStableGeneratedKey() async throws {
        DeepConformanceProtocol.outcomes = [
            .response(503, #"{"error":{"message":"retry"}}"#),
            .response(200, #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n")
        ]
        let router = try makeRouter(maxRetries: 1)

        let completion = try await router.chatCompletions(
            messages: [["role": "user", "content": "hi"]]
        )

        XCTAssertEqual(completion.choices.first?.message.content, "ok")
        XCTAssertEqual(DeepConformanceProtocol.requests.count, 2)
        let first = DeepConformanceProtocol.requests[0].value(forHTTPHeaderField: "Idempotency-Key")
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(
            DeepConformanceProtocol.requests[1].value(forHTTPHeaderField: "Idempotency-Key"),
            first
        )
    }

    func testGenericUnkeyedMutationDoesNotRetryAmbiguousTransportFailure() async throws {
        DeepConformanceProtocol.outcomes = [.failure(URLError(.networkConnectionLost))]
        let router = try makeRouter(maxRetries: 2)
        do {
            let _: EmptyResponse = try await router.request(
                method: "POST", path: "/generic-mutation", body: ["value": "once"]
            )
            XCTFail("expected transport failure")
        } catch {}
        XCTAssertEqual(DeepConformanceProtocol.requests.count, 1)
        XCTAssertNil(DeepConformanceProtocol.requests[0]
            .value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testOAuthExchangeStripsInjectedSessionDefaults() async throws {
        DeepConformanceProtocol.outcomes = [.response(200, #"{"key":"delegated"}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepConformanceProtocol.self]
        config.httpAdditionalHeaders = [
            "Authorization": "Bearer ambient",
            "Proxy-Authorization": "Bearer ambient-proxy",
            "Cookie": "session=ambient",
            "X-Api-Key": "ambient-api-key",
            "Idempotency-Key": "ambient-idempotency",
            "X-TR-CLIENT": "v=1;a=99;s=0",
            "X-TrustedRouter-Workspace": "ambient-workspace"
        ]

        let token = try await exchangeOAuthKey(
            code: "code",
            baseURL: "https://control.test/v1",
            urlSession: URLSession(configuration: config)
        )

        XCTAssertEqual(token.key, "delegated")
        let request = DeepConformanceProtocol.requests[0]
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-TR-CLIENT"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-TrustedRouter-Workspace"))
    }

    func testRedirectDelegateAlwaysSurfacesOriginalResponse() {
        let session = URLSession(configuration: .ephemeral)
        let original = URL(string: "https://api.test/v1/chat")!
        let redirected = URL(string: "https://attacker.test/collect")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(
            url: original, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.absoluteString]
        )!
        var accepted: URLRequest? = URLRequest(url: redirected)
        TrustedRouterRedirectBlocker.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirected)
        ) { accepted = $0 }
        XCTAssertNil(accepted)
    }

    private func makeRouter(maxRetries: Int) throws -> TrustedRouter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepConformanceProtocol.self]
        return try TrustedRouter(options: .init(
            apiKey: "sk-test",
            baseUrl: "https://api.test/v1",
            controlBaseURL: "https://control.test/v1",
            urlSession: URLSession(configuration: config),
            maxRetries: maxRetries,
            regionalFailover: false
        ))
    }
}

private final class DeepConformanceProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case response(Int, String)
        case failure(Error)
    }

    nonisolated(unsafe) static var outcomes: [Outcome] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        outcomes = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard !Self.outcomes.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let outcome = Self.outcomes.removeFirst()
        switch outcome {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": status == 200
                    ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
