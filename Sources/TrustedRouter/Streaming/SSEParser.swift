import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SSEEvent: Sendable {
    public var event: String?
    public var data: String
}

public typealias TrustedRouterByteStream = AsyncThrowingStream<UInt8, Error>

/// Pull cursor for the byte-to-frame layer. `AsyncThrowingStream(unfolding:)`
/// invokes this only when its consumer requests another element, so there is
/// no producer task and no queue in which an untrusted server can accumulate
/// events while the application is paused.
private final class SSEEventCursor: @unchecked Sendable {
    private var iterator: TrustedRouterByteStream.AsyncIterator
    private var buffer = Data()
    private var ended = false
    private let recorder: RequestRecorder?

    init(bytes: TrustedRouterByteStream, recorder: RequestRecorder? = nil) {
        self.iterator = bytes.makeAsyncIterator()
        self.recorder = recorder
    }

    func next() async throws -> SSEEvent? {
        guard !ended else { return nil }
        while true {
            guard let byte = try await iterator.next() else {
                ended = true
                if buffer.isEmpty { return nil }
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE stream ended inside a frame"
                )
            }
            try Task.checkCancellation()
            buffer.append(byte)
            guard buffer.count <= SSEParser.maximumFrameBytes else {
                ended = true
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE frame exceeded "
                    + "\(SSEParser.maximumFrameBytes) bytes"
                )
            }

            let hasLFBoundary = buffer.count >= 2
                && buffer.suffix(2) == Data([10, 10])
            let hasCRLFBoundary = buffer.count >= 4
                && buffer.suffix(4) == Data([13, 10, 13, 10])
            guard hasLFBoundary || hasCRLFBoundary else { continue }

            guard let frame = String(data: buffer, encoding: .utf8) else {
                ended = true
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE frame was not valid UTF-8"
                )
            }
            buffer.removeAll(keepingCapacity: true)
            if let event = SSEParser.parseFrame(frame) {
                recorder?.onFirstEvent()
                return event
            }
            // Comment-only/unknown-field frames are ignored, but still read
            // at most one delimited frame per loop with bounded memory.
        }
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public enum SSEParser {
    /// Upper bound for one not-yet-delimited event. Prevents an untrusted
    /// stream from growing the parser buffer without limit.
    public static let maximumFrameBytes = 1_048_576

    /// Low-level pull stream of raw SSE events from bytes.
    public static func stream(
        from bytes: TrustedRouterByteStream
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        stream(from: bytes, recorder: nil)
    }

    static func stream(
        from bytes: TrustedRouterByteStream,
        recorder: RequestRecorder?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        let cursor = SSEEventCursor(bytes: bytes, recorder: recorder)
        return AsyncThrowingStream(unfolding: {
            try await cursor.next()
        })
    }

    fileprivate static func parseFrame(_ frame: String) -> SSEEvent? {
        var currentEvent: String? = nil
        var dataParts: [String] = []

        let lines = frame.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("event:") {
                currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataParts.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
        }

        if dataParts.isEmpty { return nil }
        return SSEEvent(event: currentEvent, data: dataParts.joined(separator: "\n"))
    }
}

/// Pull cursor for the typed adapter. It requests exactly one raw frame at a
/// time and therefore inherits byte-to-frame backpressure without another
/// continuation buffer.
private final class TypedSSECursor<T: Decodable>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<SSEEvent, Error>.AsyncIterator
    private let decoder = JSONDecoder()
    private var finished = false
    private let recorder: RequestRecorder?

    init(events: AsyncThrowingStream<SSEEvent, Error>, recorder: RequestRecorder? = nil) {
        self.iterator = events.makeAsyncIterator()
        self.recorder = recorder
    }

    deinit {
        if !finished {
            recorder?.onAborted()
            recorder?.finish()
        }
    }

    func next() async throws -> T? {
        do {
            return try await nextValue()
        } catch is CancellationError {
            recorder?.onAborted()
            recorder?.finish()
            throw CancellationError()
        } catch {
            recorder?.onTransportError(
                error, responseOpened: true, bodyStarted: recorder?.ttftMs != nil
            )
            recorder?.finish()
            throw error
        }
    }

    private func nextValue() async throws -> T? {
        guard !finished else { return nil }
        while let event = try await iterator.next() {
            try Task.checkCancellation()
            let trimmedData = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedData == "[DONE]" {
                finished = true
                recorder?.finish()
                return nil
            }
            guard let data = trimmedData.data(using: .utf8) else {
                finished = true
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE data was not valid UTF-8"
                )
            }
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["error"] != nil {
                finished = true
                let message = ((object["error"] as? [String: Any])?["message"] as? String)
                    ?? "TrustedRouter stream returned an error"
                throw TrustedRouterError.invalidResponse(message)
            }
            return try decoder.decode(T.self, from: data)
        }
        finished = true
        throw TrustedRouterError.invalidResponse(
            "TrustedRouter SSE stream ended before [DONE]"
        )
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public func iterSseEvents<T: Decodable>(
    bytes: TrustedRouterByteStream,
    type: T.Type
) -> AsyncThrowingStream<T, Error> {
    makeTypedSSEEvents(bytes: bytes, type: type, recorder: nil)
}

func makeTypedSSEEvents<T: Decodable>(
    bytes: TrustedRouterByteStream,
    type: T.Type,
    recorder: RequestRecorder?
) -> AsyncThrowingStream<T, Error> {
    let cursor = TypedSSECursor<T>(
        events: SSEParser.stream(from: bytes, recorder: recorder),
        recorder: recorder
    )
    return AsyncThrowingStream(unfolding: {
        try await cursor.next()
    })
}

/// Pull cursor for the dynamic Responses adapter. `[String: Any]` is retained
/// for source compatibility, but no eager producer or unbounded queue is used.
private final class DictionarySSECursor: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<SSEEvent, Error>.AsyncIterator
    private var finished = false
    private let recorder: RequestRecorder?

    init(events: AsyncThrowingStream<SSEEvent, Error>, recorder: RequestRecorder? = nil) {
        self.iterator = events.makeAsyncIterator()
        self.recorder = recorder
    }

    deinit {
        if !finished {
            recorder?.onAborted()
            recorder?.finish()
        }
    }

    func next() async throws -> [String: Any]? {
        do {
            return try await nextValue()
        } catch is CancellationError {
            recorder?.onAborted()
            recorder?.finish()
            throw CancellationError()
        } catch {
            recorder?.onTransportError(
                error, responseOpened: true, bodyStarted: recorder?.ttftMs != nil
            )
            recorder?.finish()
            throw error
        }
    }

    private func nextValue() async throws -> [String: Any]? {
        guard !finished else { return nil }
        while let event = try await iterator.next() {
            try Task.checkCancellation()
            let trimmedData = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedData == "[DONE]" {
                finished = true
                recorder?.finish()
                return nil
            }
            guard let data = trimmedData.data(using: .utf8) else {
                finished = true
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE data was not valid UTF-8"
                )
            }
            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: data)
            } catch {
                finished = true
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE data was not a valid JSON object"
                )
            }
            guard var payload = decoded as? [String: Any] else {
                finished = true
                throw TrustedRouterError.invalidResponse(
                    "TrustedRouter SSE data was not a JSON object"
                )
            }
            if let error = payload["error"] {
                finished = true
                let message = ((error as? [String: Any])?["message"] as? String)
                    ?? "TrustedRouter stream returned an error"
                throw TrustedRouterError.invalidResponse(message)
            }
            if let eventName = event.event, payload["event"] == nil {
                payload["event"] = eventName
            }
            return payload
        }
        finished = true
        throw TrustedRouterError.invalidResponse(
            "TrustedRouter SSE stream ended before [DONE]"
        )
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public func iterSseEvents(
    bytes: TrustedRouterByteStream
) -> AsyncThrowingStream<[String: Any], Error> {
    makeDictionarySSEEvents(bytes: bytes, recorder: nil)
}

func makeDictionarySSEEvents(
    bytes: TrustedRouterByteStream,
    recorder: RequestRecorder?
) -> AsyncThrowingStream<[String: Any], Error> {
    let cursor = DictionarySSECursor(
        events: SSEParser.stream(from: bytes, recorder: recorder),
        recorder: recorder
    )
    return AsyncThrowingStream(unfolding: {
        try await cursor.next()
    })
}
