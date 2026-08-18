import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SSE parser correctness: frame boundaries, multi-line `data:`, UTF-8
/// multi-byte chars (the v0.3.1 regression), the [DONE] sentinel, the
/// typed `iterSseEvents<T>` decoder, and the untyped dict fallback.
///
/// Drives the parser via in-process `URLProtocol` mocks so no network.
final class SSEParserTests: XCTestCase {

    func testFrameBoundaryLFLFEmitsEvent() async throws {
        let chunks = ["data: hello\n\n"]
        let events = try await collectSSEEvents(chunks: chunks)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testFrameBoundaryCRLFCRLFAlsoWorks() async throws {
        let chunks = ["data: hello\r\n\r\n"]
        let events = try await collectSSEEvents(chunks: chunks)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testEventTypePreservedAcrossFrames() async throws {
        let chunks = [
            "event: thinking\ndata: hmm\n\n",
            "event: answer\ndata: 42\n\n",
        ]
        let events = try await collectSSEEvents(chunks: chunks)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "thinking")
        XCTAssertEqual(events[0].data, "hmm")
        XCTAssertEqual(events[1].event, "answer")
        XCTAssertEqual(events[1].data, "42")
    }

    func testMultiLineDataLinesAreJoinedWithNewline() async throws {
        let chunks = ["data: line one\ndata: line two\n\n"]
        let events = try await collectSSEEvents(chunks: chunks)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "line one\nline two")
    }

    func testMultiByteUTF8SurvivesByteSplitBoundary() async throws {
        // Em-dash "—" is 0xE2 0x80 0x94 in UTF-8. Smart quote "" is
        // 0xE2 0x80 0x9D. Burying these in the middle of an SSE frame and
        // splitting the response across multiple chunks (so the bytes of
        // a single codepoint cross chunk boundaries) is exactly the case
        // the v0.3.1 byte-at-a-time decoder dropped silently.
        let payload = "answer — ok"
        let bytes = Array(payload.utf8)
        // Split the bytes mid-codepoint so each chunk is invalid UTF-8 alone.
        // "answer " (7) + first byte of em-dash (1) | rest of em-dash (2)
        // + " ok\n\n" — guaranteed to break a byte-by-byte decoder.
        let prefix = Data([UInt8](bytes[0..<8]))
        let suffix = Data([UInt8](bytes[8...]) + Array("\n\n".utf8))
        let chunks = ["data: ", String(data: prefix, encoding: .utf8) ?? ""]
            + [Data(bytes[8...]).map { String(format: "%c", $0) }.joined() + "\n\n"]
        // Simpler: just hand both halves directly as Data and re-stitch.
        _ = chunks
        let events = try await collectSSEEventsRaw(chunks: [Data("data: ".utf8) + prefix, suffix])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, payload)
    }

    func testDONESentinelSkippedByTypedIterator() async throws {
        struct Echo: Decodable, Equatable { let token: String }
        let chunks = [
            #"data: {"token":"hi"}"# + "\n\n",
            "data: [DONE]\n\n",
        ]
        let bytes = try await mockAsyncBytes(chunks: chunks)
        var out: [Echo] = []
        for try await event in iterSseEvents(bytes: bytes, type: Echo.self) {
            out.append(event)
        }
        XCTAssertEqual(out, [Echo(token: "hi")])
    }

    func testTypedIteratorRejectsUndecodableFrames() async throws {
        struct Echo: Decodable, Equatable { let token: String }
        let chunks = [
            "data: ping\n\n",
            #"data: {"token":"hi"}"# + "\n\n",
        ]
        let bytes = try await mockAsyncBytes(chunks: chunks)
        do {
            for try await _ in iterSseEvents(bytes: bytes, type: Echo.self) {}
            XCTFail("expected malformed stream to fail closed")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testDictIteratorRejectsNonJSONData() async throws {
        let chunks = ["data: not json\n\n"]
        let bytes = try await mockAsyncBytes(chunks: chunks)
        do {
            for try await _ in iterSseEvents(bytes: bytes) {}
            XCTFail("expected malformed stream to fail closed")
        } catch TrustedRouterError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("JSON object"))
        }
    }

    func testDictIteratorIncludesEventNameWhenPresent() async throws {
        let chunks = [#"event: hello\ndata: {"k":1}\n\n"#]
        // The above used escaped \n inside a raw string by mistake; rewrite:
        let real = "event: hello\ndata: {\"k\":1}\n\n"
        let bytes = try await mockAsyncBytes(chunks: [real, "data: [DONE]\n\n"])
        _ = chunks
        var out: [[String: Any]] = []
        for try await event in iterSseEvents(bytes: bytes) {
            out.append(event)
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?["event"] as? String, "hello")
        XCTAssertEqual(out.first?["k"] as? Int, 1)
    }

    func testTrailingFrameWithoutTerminatorFailsClosed() async throws {
        let chunks = ["data: tail\n"]  // missing the final \n
        do {
            _ = try await collectSSEEvents(chunks: chunks)
            XCTFail("expected incomplete frame failure")
        } catch TrustedRouterError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("inside a frame"))
        }
    }

    func testTypedIteratorRejectsEOFBeforeDone() async throws {
        struct Echo: Decodable { let token: String }
        let bytes = try await mockAsyncBytes(chunks: [#"data: {"token":"hi"}"# + "\n\n"])
        do {
            for try await _ in iterSseEvents(bytes: bytes, type: Echo.self) {}
            XCTFail("expected missing [DONE] failure")
        } catch TrustedRouterError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("before [DONE]"))
        }
    }

    func testOversizedFrameIsRejected() async throws {
        let huge = "data: " + String(repeating: "x", count: SSEParser.maximumFrameBytes) + "\n\n"
        do {
            _ = try await collectSSEEvents(chunks: [huge])
            XCTFail("expected frame bound failure")
        } catch TrustedRouterError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("exceeded"))
        }
    }

    func testRawParserPullsOnlyThroughTheDemandedFrame() async throws {
        let firstFrame = "data: first\n\n"
        let secondFrame = "data: second\n\n"
        let counter = PullCountingBytes(Data((firstFrame + secondFrame).utf8))
        let stream = SSEParser.stream(from: counter.stream())

        let initialPulls = await counter.pullCount
        XCTAssertEqual(initialPulls, 0)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.data, "first")
        let pullsAfterFirst = await counter.pullCount
        XCTAssertEqual(pullsAfterFirst, Data(firstFrame.utf8).count)
        for _ in 0..<10 { await Task.yield() }
        let pullsWhileIdle = await counter.pullCount
        XCTAssertEqual(pullsWhileIdle, Data(firstFrame.utf8).count)

        let second = try await iterator.next()
        XCTAssertEqual(second?.data, "second")
        let finalPulls = await counter.pullCount
        XCTAssertEqual(finalPulls, Data((firstFrame + secondFrame).utf8).count)
    }

    func testTypedAdapterAddsNoEagerQueue() async throws {
        struct Echo: Decodable { let token: String }
        let firstFrame = "data: {\"token\":\"one\"}\n\n"
        let rest = "data: {\"token\":\"two\"}\n\ndata: [DONE]\n\n"
        let counter = PullCountingBytes(Data((firstFrame + rest).utf8))
        let stream = iterSseEvents(bytes: counter.stream(), type: Echo.self)

        let initialPulls = await counter.pullCount
        XCTAssertEqual(initialPulls, 0)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.token, "one")
        let afterFirst = await counter.pullCount
        XCTAssertEqual(afterFirst, Data(firstFrame.utf8).count)
        for _ in 0..<10 { await Task.yield() }
        let afterIdle = await counter.pullCount
        XCTAssertEqual(afterIdle, afterFirst)
    }

    func testDictionaryAdapterAddsNoEagerQueue() async throws {
        let firstFrame = "event: one\ndata: {\"value\":1}\n\n"
        let rest = "event: two\ndata: {\"value\":2}\n\ndata: [DONE]\n\n"
        let counter = PullCountingBytes(Data((firstFrame + rest).utf8))
        let stream = iterSseEvents(bytes: counter.stream())

        let initialPulls = await counter.pullCount
        XCTAssertEqual(initialPulls, 0)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?["event"] as? String, "one")
        XCTAssertEqual(first?["value"] as? Int, 1)
        let afterFirst = await counter.pullCount
        XCTAssertEqual(afterFirst, Data(firstFrame.utf8).count)
        for _ in 0..<10 { await Task.yield() }
        let afterIdle = await counter.pullCount
        XCTAssertEqual(afterIdle, afterFirst)
    }

    func testChatTextAdapterAddsNoEagerQueue() async throws {
        let chunks = [
            ChatCompletionChunk(
                id: "c1", object: nil, created: nil, model: "m",
                choices: [.init(
                    index: 0,
                    delta: .init(role: "assistant", content: nil),
                    finishReason: nil
                )]
            ),
            ChatCompletionChunk(
                id: "c1", object: nil, created: nil, model: "m",
                choices: [.init(
                    index: 0,
                    delta: .init(role: nil, content: "one"),
                    finishReason: nil
                )]
            ),
            ChatCompletionChunk(
                id: "c1", object: nil, created: nil, model: "m",
                choices: [.init(
                    index: 0,
                    delta: .init(role: nil, content: "two"),
                    finishReason: "stop"
                )]
            )
        ]
        let counter = PullCountingChatChunks(chunks)
        let stream = chatTextStream(from: counter.stream())

        let initialPulls = await counter.pullCount
        XCTAssertEqual(initialPulls, 0)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, "one")
        let afterFirst = await counter.pullCount
        XCTAssertEqual(afterFirst, 2)
        for _ in 0..<10 { await Task.yield() }
        let afterIdle = await counter.pullCount
        XCTAssertEqual(afterIdle, afterFirst)
        let second = try await iterator.next()
        XCTAssertEqual(second, "two")
        let finalPulls = await counter.pullCount
        XCTAssertEqual(finalPulls, 3)
    }

    func testBufferedBodyReplayIsPullBasedAndDocumentsPlatformCapability() async throws {
        let stream = TrustedRouter.byteStream(from: Data([1, 2, 3]))
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()
        let third = try await iterator.next()
        let end = try await iterator.next()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 3)
        XCTAssertNil(end)
        #if os(Linux)
        XCTAssertFalse(TrustedRouter.hasLiveResponseByteStreaming)
        #else
        XCTAssertTrue(TrustedRouter.hasLiveResponseByteStreaming)
        #endif
    }

    // MARK: - Harness

    /// Push pre-baked SSE chunks through a mocked URLSession, return the
    /// raw `SSEEvent`s as the parser observed them.
    private func collectSSEEvents(chunks: [String]) async throws -> [SSEEvent] {
        try await collectSSEEventsRaw(chunks: chunks.map { Data($0.utf8) })
    }

    private func collectSSEEventsRaw(chunks: [Data]) async throws -> [SSEEvent] {
        let bytes = try await mockAsyncBytes(chunks: chunks)
        var events: [SSEEvent] = []
        for try await event in SSEParser.stream(from: bytes) {
            events.append(event)
        }
        return events
    }

    private func mockAsyncBytes(chunks: [String]) async throws -> TrustedRouterByteStream {
        try await mockAsyncBytes(chunks: chunks.map { Data($0.utf8) })
    }

    private func mockAsyncBytes(chunks: [Data]) async throws -> TrustedRouterByteStream {
        let body = chunks.reduce(Data(), +)
        // Use a self-contained URLProtocol that yields the bytes as a single
        // response payload. We can't easily fragment URLSession bytes across the
        // network mock, but the parser is byte-at-a-time so the result is
        // equivalent: it sees one byte at a time regardless.
        MockSSEURLProtocol.body = body
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSSEURLProtocol.self]
        let session = URLSession(configuration: config)
        let req = URLRequest(url: URL(string: "https://mock.invalid/stream")!)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "MockSSEURLProtocol", code: 1)
        }
        return TrustedRouterByteStream { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }
}

private actor PullCountingBytes {
    private let bytes: Data
    private var index = 0
    private var pulls = 0

    init(_ bytes: Data) { self.bytes = bytes }

    var pullCount: Int { pulls }

    nonisolated func stream() -> TrustedRouterByteStream {
        TrustedRouterByteStream(unfolding: { [self] in
            await next()
        })
    }

    private func next() -> UInt8? {
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        index += 1
        pulls += 1
        return byte
    }
}

private actor PullCountingChatChunks {
    private let chunks: [ChatCompletionChunk]
    private var index = 0
    private var pulls = 0

    init(_ chunks: [ChatCompletionChunk]) { self.chunks = chunks }

    var pullCount: Int { pulls }

    nonisolated func stream() -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream(unfolding: { [self] in
            await next()
        })
    }

    private func next() -> ChatCompletionChunk? {
        guard index < chunks.count else { return nil }
        let chunk = chunks[index]
        index += 1
        pulls += 1
        return chunk
    }
}

private final class MockSSEURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
