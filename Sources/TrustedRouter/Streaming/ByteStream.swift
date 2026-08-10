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

    /// Replay a fully-buffered body as a byte stream. This is the ONLY
    /// streaming shape on Linux: FoundationNetworking has no `AsyncBytes`,
    /// so Linux "streaming" buffers via `data(for:)` and replays — the
    /// generic payload must not promise true streaming there.
    static func byteStream(from data: Data) -> TrustedRouterByteStream {
        TrustedRouterByteStream { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
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
        response: HTTPURLResponse
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
        return classifyErrorPublic(statusCode: response.statusCode, data: collected, response: response)
    }
}
