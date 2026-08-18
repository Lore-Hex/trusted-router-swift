import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SSEEvent: Sendable {
    public var event: String?
    public var data: String
}

public typealias TrustedRouterByteStream = AsyncThrowingStream<UInt8, Error>

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public enum SSEParser {
    /// Upper bound for one not-yet-delimited event. Prevents an untrusted
    /// stream from growing the parser buffer without limit.
    public static let maximumFrameBytes = 1_048_576
    
    /// Low-level stream of raw SSE events from bytes.
    public static func stream(from bytes: TrustedRouterByteStream) -> AsyncThrowingStream<SSEEvent, Error> {
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        guard buffer.count <= maximumFrameBytes else {
                            throw TrustedRouterError.invalidResponse(
                                "TrustedRouter SSE frame exceeded \(maximumFrameBytes) bytes"
                            )
                        }
                        
                        // Check for frame boundary: \n\n (10, 10) or \r\n\r\n (13, 10, 13, 10)
                        if buffer.count >= 2 && buffer.suffix(2) == Data([10, 10]) {
                            guard let frame = String(data: buffer, encoding: .utf8) else {
                                throw TrustedRouterError.invalidResponse(
                                    "TrustedRouter SSE frame was not valid UTF-8"
                                )
                            }
                            if let event = parseFrame(frame) {
                                continuation.yield(event)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else if buffer.count >= 4 && buffer.suffix(4) == Data([13, 10, 13, 10]) {
                            guard let frame = String(data: buffer, encoding: .utf8) else {
                                throw TrustedRouterError.invalidResponse(
                                    "TrustedRouter SSE frame was not valid UTF-8"
                                )
                            }
                            if let event = parseFrame(frame) {
                                continuation.yield(event)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    
                    if !buffer.isEmpty {
                        throw TrustedRouterError.invalidResponse(
                            "TrustedRouter SSE stream ended inside a frame"
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
    
    private static func parseFrame(_ frame: String) -> SSEEvent? {
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

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public func iterSseEvents<T: Decodable>(bytes: TrustedRouterByteStream, type: T.Type) -> AsyncThrowingStream<T, Error> {
    let decoder = JSONDecoder()
    let rawStream = SSEParser.stream(from: bytes)
    
    return AsyncThrowingStream { continuation in
        let producer = Task {
            do {
                var sawDone = false
                for try await event in rawStream {
                    try Task.checkCancellation()
                    let trimmedData = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedData == "[DONE]" {
                        sawDone = true
                        break
                    }
                    guard let data = trimmedData.data(using: .utf8) else {
                        throw TrustedRouterError.invalidResponse(
                            "TrustedRouter SSE data was not valid UTF-8"
                        )
                    }
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       object["error"] != nil {
                        let message = ((object["error"] as? [String: Any])?["message"] as? String)
                            ?? "TrustedRouter stream returned an error"
                        throw TrustedRouterError.invalidResponse(message)
                    }
                    let model = try decoder.decode(T.self, from: data)
                    continuation.yield(model)
                }
                guard sawDone else {
                    throw TrustedRouterError.invalidResponse(
                        "TrustedRouter SSE stream ended before [DONE]"
                    )
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
public func iterSseEvents(bytes: TrustedRouterByteStream) -> AsyncThrowingStream<[String: Any], Error> {
    let rawStream = SSEParser.stream(from: bytes)
    
    return AsyncThrowingStream { continuation in
        let producer = Task {
            do {
                var sawDone = false
                for try await event in rawStream {
                    try Task.checkCancellation()
                    let trimmedData = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedData == "[DONE]" {
                        sawDone = true
                        break
                    }
                    guard let data = trimmedData.data(using: .utf8) else {
                        throw TrustedRouterError.invalidResponse(
                            "TrustedRouter SSE data was not valid UTF-8"
                        )
                    }
                    guard var payload = try JSONSerialization.jsonObject(with: data)
                            as? [String: Any] else {
                        throw TrustedRouterError.invalidResponse(
                            "TrustedRouter SSE data was not a JSON object"
                        )
                    }
                    if let error = payload["error"] {
                        let message = ((error as? [String: Any])?["message"] as? String)
                            ?? "TrustedRouter stream returned an error"
                        throw TrustedRouterError.invalidResponse(message)
                    }
                    if let eventName = event.event, payload["event"] == nil {
                        payload["event"] = eventName
                    }
                    continuation.yield(payload)
                }
                guard sawDone else {
                    throw TrustedRouterError.invalidResponse(
                        "TrustedRouter SSE stream ended before [DONE]"
                    )
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
    }
}
