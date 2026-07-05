import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming endpoints that 4xx/5xx out before any SSE frames are sent
/// should surface the server's actual error body, not a generic message.
final class StreamingErrorTests: XCTestCase {

    func testChatCompletionsChunks401ContainsServerMessage() async throws {
        ErrorBodyProtocol.scripted = (401, #"{"error":{"message":"bad api key"}}"#)
        let router = try TrustedRouter(options: makeOptions())
        do {
            _ = try await router.chatCompletionsChunks(
                messages: [["role": "user", "content": "hi"]]
            )
            XCTFail("expected authentication error")
        } catch TrustedRouterError.authentication(let code, let msg, _) {
            XCTAssertEqual(code, 401)
            XCTAssertEqual(msg, "bad api key",
                           "the server-side message must propagate through the streaming error path")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testResponsesEvents403ContainsServerMessage() async throws {
        ErrorBodyProtocol.scripted = (403, #"{"error":{"message":"workspace lacks billing"}}"#)
        let router = try TrustedRouter(options: makeOptions())
        do {
            _ = try await router.responsesEvents(input: "hi")
            XCTFail("expected permissionDenied")
        } catch TrustedRouterError.permissionDenied(_, let msg, _) {
            XCTAssertEqual(msg, "workspace lacks billing")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testChatCompletionsChunksRetriesFailoverableStatusAgainstApex() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StreamSequenceProtocol.self]
        StreamSequenceProtocol.reset()
        let router = try TrustedRouter(options: TrustedRouterOptions(
            apiKey: "key",
            urlSession: URLSession(configuration: cfg),
            maxRetries: 1
        ))

        StreamSequenceProtocol.scripted = [
            (503, #"{"error":{"message":"temporarily unavailable"}}"#),
            (200, #"data: {"id":"chat-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\n"),
        ]

        let stream = try await router.chatCompletionsChunks(
            messages: [["role": "user", "content": "hi"]]
        )
        var chunks: [ChatCompletionChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(StreamSequenceProtocol.served, 2)
        XCTAssertEqual(StreamSequenceProtocol.requestedHosts, ["api.trustedrouter.com", "api.trustedrouter.com"])
        XCTAssertEqual(chunks.first?.choices.first?.delta?.content, "ok")
    }

    private func makeOptions() -> TrustedRouterOptions {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ErrorBodyProtocol.self]
        return TrustedRouterOptions(
            apiKey: "key",
            baseUrl: "https://test.local/v1",
            urlSession: URLSession(configuration: cfg),
            maxRetries: 0
        )
    }
}

private final class ErrorBodyProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scripted: (Int, String) = (500, "")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.scripted
        let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StreamSequenceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var scripted: [(Int, String)] = []
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
        let (code, body) = idx < Self.scripted.count ? Self.scripted[idx] : (500, "")
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": code == 200 ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
