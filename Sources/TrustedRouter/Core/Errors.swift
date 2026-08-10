import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L6 — ERROR TAXONOMY. The single typed error hierarchy plus the
// status→error classifier. OAuth and attestation reuse these types; no
// private duplicates exist anywhere in the module.

/// Every error the SDK surfaces. Each HTTP-status case carries the original
/// status code, the server's message (parsed from `error.message` or
/// `message` if present, otherwise the raw body), and the decoded payload
/// for callers that need to inspect provider-specific fields.
public enum TrustedRouterError: Error, LocalizedError, CustomStringConvertible {
    case badRequest(statusCode: Int, message: String, payload: [String: Any]?)
    case authentication(statusCode: Int, message: String, payload: [String: Any]?)
    case permissionDenied(statusCode: Int, message: String, payload: [String: Any]?)
    case notFound(statusCode: Int, message: String, payload: [String: Any]?)
    case endpointNotSupported(statusCode: Int, message: String, payload: [String: Any]?)
    case rateLimit(statusCode: Int, message: String, payload: [String: Any]?, retryAfterSeconds: Double?)
    case internalError(String)
    case generic(statusCode: Int, message: String, payload: [String: Any]?)
    case invalidResponse(String)

    public var errorDescription: String? { description }

    /// Routing layer supplied by the actionable API error envelope.
    public var layer: String? { attribution("layer") }
    /// Gateway or provider error source supplied by the API.
    public var source: String? { attribution("source") }
    /// Attempted provider when supplied by the gateway.
    public var provider: String? { attribution("provider") }
    /// Request identifier for metadata-log correlation.
    public var requestID: String? { attribution("request_id") }

    private func attribution(_ key: String) -> String? {
        let payload: [String: Any]?
        switch self {
        case let .badRequest(_, _, value), let .authentication(_, _, value),
             let .permissionDenied(_, _, value), let .notFound(_, _, value),
             let .endpointNotSupported(_, _, value), let .generic(_, _, value),
             let .rateLimit(_, _, value, _):
            payload = value
        case .internalError, .invalidResponse:
            payload = nil
        }
        let detail = (payload?["error"] as? [String: Any]) ?? payload
        return detail?[key] as? String
    }
    public var description: String {
        switch self {
        case let .badRequest(statusCode, message, _),
             let .authentication(statusCode, message, _),
             let .permissionDenied(statusCode, message, _),
             let .notFound(statusCode, message, _),
             let .endpointNotSupported(statusCode, message, _),
             let .generic(statusCode, message, _):
            return "[\(statusCode)] \(message)"
        case let .rateLimit(statusCode, message, _, retryAfterSeconds):
            if let retryAfterSeconds {
                return "[\(statusCode)] \(message) (retry after \(retryAfterSeconds)s)"
            }
            return "[\(statusCode)] \(message)"
        case .internalError(let message), .invalidResponse(let message):
            return message
        }
    }
}

extension TrustedRouter {
    /// Package-internal entry to the error classifier, used by the streaming
    /// methods when they drain a non-200 SSE response body before throwing.
    func classifyErrorPublic(statusCode: Int, data: Data?, response: HTTPURLResponse) -> TrustedRouterError {
        classifyError(statusCode: statusCode, data: data, response: response)
    }

    func classifyError(statusCode: Int, data: Data?, response: HTTPURLResponse) -> TrustedRouterError {
        var message = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var payload: [String: Any]? = nil

        if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = obj
            if let err = obj["error"] as? [String: Any] {
                message = (err["message"] as? String) ?? (err["type"] as? String) ?? message
            } else if let msg = obj["message"] as? String {
                message = msg
            }
        } else if let data = data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            message = str
            payload = ["message": str]
        }

        let retryAfter = RetryPolicy.parseRetryAfter(response)

        switch statusCode {
        case 401: return .authentication(statusCode: statusCode, message: message, payload: payload)
        case 403: return .permissionDenied(statusCode: statusCode, message: message, payload: payload)
        case 404: return .notFound(statusCode: statusCode, message: message, payload: payload)
        case 429: return .rateLimit(statusCode: statusCode, message: message, payload: payload, retryAfterSeconds: retryAfter)
        case 501: return .endpointNotSupported(statusCode: statusCode, message: message, payload: payload)
        case 400..<500: return .badRequest(statusCode: statusCode, message: message, payload: payload)
        case 500...: return .generic(statusCode: statusCode, message: message, payload: payload)
        default: return .generic(statusCode: statusCode, message: message, payload: payload)
        }
    }
}
