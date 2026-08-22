import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L5 — STREAM CODEC adapters. Pure wrappers over an opened response body.
// No retry logic may ever live here: by the time one of these streams
// exists, the transport engine has already made its final decision for the
// attempt that produced it (invariant 6 — a broken open stream propagates,
// never reconnects).

extension TrustedRouter {

    /// Lifecycle wrapper for callers of the low-level raw stream API. It
    /// records completion, cancellation and mid-body transport failure, but
    /// deliberately leaves TTFT nil: only SSEParser may mark a first event.
    static func telemetryByteStream(
        from bytes: TrustedRouterByteStream,
        recorder: RequestRecorder?
    ) -> TrustedRouterByteStream {
        guard let recorder else { return bytes }
        final class Cursor: @unchecked Sendable {
            var iterator: TrustedRouterByteStream.AsyncIterator
            let recorder: RequestRecorder
            var bodyStarted = false
            init(_ bytes: TrustedRouterByteStream, recorder: RequestRecorder) {
                iterator = bytes.makeAsyncIterator()
                self.recorder = recorder
            }
            func next() async throws -> UInt8? {
                do {
                    try Task.checkCancellation()
                    let value = try await iterator.next()
                    if value == nil { recorder.finish() }
                    else { bodyStarted = true }
                    return value
                } catch is CancellationError {
                    recorder.onAborted()
                    recorder.finish()
                    throw CancellationError()
                } catch {
                    recorder.onTransportError(
                        error, responseOpened: true, bodyStarted: bodyStarted
                    )
                    recorder.finish()
                    throw error
                }
            }
        }
        let cursor = Cursor(bytes, recorder: recorder)
        return TrustedRouterByteStream(unfolding: { try await cursor.next() })
    }

    /// Replay a fully-buffered body as a pull byte stream. This is the ONLY
    /// transport shape on Linux: FoundationNetworking has no `AsyncBytes`,
    /// so Linux waits for `data(for:)` to finish and then exposes one buffered
    /// byte per downstream demand. It is not live network streaming, but it
    /// also does not enqueue a second eager copy of the entire body.
    static func byteStream(from data: Data) -> TrustedRouterByteStream {
        final class Cursor: @unchecked Sendable {
            let data: Data
            var index = 0

            init(data: Data) { self.data = data }
        }
        let cursor = Cursor(data: data)
        return TrustedRouterByteStream(unfolding: {
            guard cursor.index < cursor.data.count else { return nil }
            let byte = cursor.data[cursor.index]
            cursor.index += 1
            return byte
        })
    }

    /// Platform capability exposed internally for tests and documentation:
    /// Darwin reads live URLSession bytes; Linux performs bounded-memory pull
    /// replay only after FoundationNetworking buffers the HTTP body.
    static var hasLiveResponseByteStreaming: Bool {
        #if os(Linux)
        return false
        #else
        return true
        #endif
    }

    #if !os(Linux)
    /// Wrap live `URLSession.AsyncBytes` as a byte stream.
    ///
    /// Construction is deliberately LAZY: no reader work happens until the
    /// caller's first iteration. The transport engine constructs this wrapper
    /// on every attempt and simply drops it when the attempt is retried —
    /// eager reading here would leak a reader task per discarded attempt.
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    static func byteStream(from bytes: URLSession.AsyncBytes) -> TrustedRouterByteStream {
        final class IteratorBox: @unchecked Sendable {
            var iterator: URLSession.AsyncBytes.AsyncIterator?
        }
        let box = IteratorBox()
        return TrustedRouterByteStream(unfolding: {
            if box.iterator == nil {
                box.iterator = bytes.makeAsyncIterator()
            }
            return try await box.iterator!.next()
        })
    }
    #endif

    /// Drain `bytes` into a `Data` buffer and classify as a
    /// `TrustedRouterError` using the same logic as non-streaming requests.
    /// Used when a stream endpoint returns a 4xx/5xx status before any SSE
    /// frames are sent — the body usually contains the actual error message.
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    func streamingError(
        bytes: TrustedRouterByteStream,
        response: HTTPURLResponse,
        recorder: RequestRecorder? = nil
    ) async throws -> TrustedRouterError {
        var collected = Data()
        do {
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 64 * 1024 { break } // safety cap
            }
        } catch {
            // Body drained as much as we could; classify with what we got.
        }
        recorder?.onErrorBody(collected)
        return classifyErrorPublic(statusCode: response.statusCode, data: collected, response: response)
    }
}
