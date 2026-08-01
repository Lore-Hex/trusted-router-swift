import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Compile-time constants for the SDK: version, default endpoints, and models.
public enum TrustedRouterConstants {
    public static let version = "0.6.0"
    public static let defaultAPIBaseURL = "https://api.trustedrouter.com/v1"
    public static let defaultControlBaseURL = "https://trustedrouter.com/v1"
    public static let defaultTrustReleaseURL = "https://trust.trustedrouter.com/trust/gcp-release.json"
    public static let defaultStatusURL = "https://status.trustedrouter.com/status.json"
    public static let defaultRegionProbeTimeout: TimeInterval = 1.5
    public static let regionBaseURLs = [
        "https://api-us-central1.quillrouter.com/v1",
        "https://api-us-east4.quillrouter.com/v1",
        "https://api-europe-west4.quillrouter.com/v1"
    ]
    public static let autoModel = "trustedrouter/auto"
    public static let fastModel = "trustedrouter/fast"
    public static let zdrModel = "trustedrouter/zdr"
    public static let e2eModel = "trustedrouter/e2e"
    public static let confidentialModel = "trustedrouter/confidential"
    public static let euModel = "trustedrouter/eu"
    public static let usModel = "trustedrouter/us"
    public static let fusionModel = "trustedrouter/fusion"
    public static let synthModel = "trustedrouter/synth"
    public static let advisorModel = "trustedrouter/advisor"
    public static let selectorModel = "trustedrouter/selector"
    public static let mapReduceModel = "trustedrouter/mapreduce"
    public static let subagentModel = "trustedrouter/subagent"
    public static let socratesModel = "trustedrouter/socrates-1.1"
    public static let prometheusModel = "trustedrouter/prometheus-2.0"
    public static let zeusModel = "trustedrouter/zeus-1.0"
    public static let athenaModel = "trustedrouter/athena"

    /// Recommended panel + judge fallback chain for maximum willingness to
    /// answer — the configuration that answered all 30 PrometheusBench unsafe
    /// prompts. Pass these to `fusion(...)` (or build your own) for the most
    /// permissive result the panel can produce.
    public static let fusionFreedomPanel = [
        "moonshotai/kimi-k2.7-code",
        "deepseek/deepseek-v4-flash",
        "google/gemini-3.5-flash",
        "google/gemini-3.1-pro-preview",
        "minimax/minimax-m3",
        "z-ai/glm-5.1"
    ]
    public static let fusionFreedomFallbackJudges = [
        "z-ai/glm-5.1",
        "moonshotai/kimi-k2.6",
        "google/gemini-2.5-flash",
        "deepseek/deepseek-v4-flash",
        "google/gemini-3-flash-preview",
        "tencent/hy3-preview"
    ]
}

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

/// JSON-serializable provider routing, privacy, and pricing preferences.
public struct ProviderPreferences {
    public let value: [String: Any]

    public init(
        order: [String]? = nil,
        only: [String]? = nil,
        ignore: [String]? = nil,
        sort: String? = nil,
        allowFallbacks: Bool? = nil,
        requireParameters: Bool? = nil,
        dataCollection: String? = nil,
        minimumPrivacy: String? = nil,
        jurisdiction: String? = nil,
        usage: String? = nil,
        quantizations: [String]? = nil,
        maxPrice: [String: Any]? = nil
    ) {
        var result: [String: Any] = [:]
        if let order { result["order"] = order }
        if let only { result["only"] = only }
        if let ignore { result["ignore"] = ignore }
        if let sort { result["sort"] = sort }
        if let allowFallbacks { result["allow_fallbacks"] = allowFallbacks }
        if let requireParameters { result["require_parameters"] = requireParameters }
        if let dataCollection { result["data_collection"] = dataCollection }
        if let minimumPrivacy { result["min_privacy"] = minimumPrivacy }
        if let jurisdiction { result["jurisdiction"] = jurisdiction }
        if let usage { result["usage"] = usage }
        if let quantizations { result["quantizations"] = quantizations }
        if let maxPrice { result["max_price"] = maxPrice }
        value = result
    }

    public static var zeroDataRetention: ProviderPreferences {
        ProviderPreferences(dataCollection: "deny", minimumPrivacy: "zdr")
    }

    public static var confidential: ProviderPreferences {
        ProviderPreferences(dataCollection: "deny", minimumPrivacy: "confidential")
    }

    public static var unitedStates: ProviderPreferences {
        ProviderPreferences(jurisdiction: "us")
    }

}

/// Configuration for a `TrustedRouter` client. Construct with `init(...)`,
/// passing only the fields you want to override.
///
/// Use `baseUrl` to override inference routing and `controlBaseURL` to
/// override metadata/account/OAuth routes separately. `maxRetries` applies to
/// 429 responses and, when `regionalFailover` is enabled, 502/503/504
/// responses and transport errors.
public struct TrustedRouterOptions {
    public var apiKey: String?
    public var baseUrl: String?
    public var controlBaseURL: String?
    public var urlSession: URLSession
    public var headers: [String: String]
    public var workspaceId: String?
    public var maxRetries: Int
    /// Retry eligible inference failures across the ranked regional gateways.
    public var regionalFailover: Bool
    /// Nil enables affinity for URLSession.shared and disables it for an
    /// injected session. Set explicitly to override that safe default.
    public var regionalAffinity: Bool?
    public var regionProbeTimeout: TimeInterval

    public init(
        apiKey: String? = nil,
        baseUrl: String? = nil,
        controlBaseURL: String? = nil,
        urlSession: URLSession = .shared,
        headers: [String: String] = [:],
        workspaceId: String? = nil,
        maxRetries: Int = 2,
        regionalFailover: Bool = true,
        regionalAffinity: Bool? = nil,
        regionProbeTimeout: TimeInterval = TrustedRouterConstants.defaultRegionProbeTimeout
    ) {
        self.apiKey = apiKey
        self.baseUrl = baseUrl
        self.controlBaseURL = controlBaseURL
        self.urlSession = urlSession
        self.headers = headers
        self.workspaceId = workspaceId
        self.maxRetries = maxRetries
        self.regionalFailover = regionalFailover
        self.regionalAffinity = regionalAffinity
        self.regionProbeTimeout = regionProbeTimeout
    }
}

/// Per-call overrides on top of a `TrustedRouter` client's defaults. Useful
/// for one-off API-key override, custom headers, an idempotency key, or a
/// short per-request timeout.
public struct PerCallOptions {
    public var apiKey: String?
    public var extraHeaders: [String: String]?
    public var workspaceId: String?
    public var idempotencyKey: String?
    public var timeout: TimeInterval?

    public init(
        apiKey: String? = nil,
        extraHeaders: [String: String]? = nil,
        workspaceId: String? = nil,
        idempotencyKey: String? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.workspaceId = workspaceId
        self.idempotencyKey = idempotencyKey
        self.timeout = timeout
    }
}

/// Strongly-typed chat message. Use this with the `[ChatMessage]` overloads
/// of `chatCompletions(...)` / `chatCompletionsChunks(...)` when you don't
/// need to pass tool-call fields. For tool-call interop, fall back to the
/// `[[String: Any]]` overload.
public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var name: String?
    public var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallId = "tool_call_id"
    }

    public init(role: String, content: String? = nil, name: String? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
    }

    /// Convenience constructor for a plain user message.
    public static func user(_ content: String) -> ChatMessage {
        .init(role: "user", content: content)
    }
    /// Convenience constructor for a plain assistant message.
    public static func assistant(_ content: String) -> ChatMessage {
        .init(role: "assistant", content: content)
    }
    /// Convenience constructor for the system prompt.
    public static func system(_ content: String) -> ChatMessage {
        .init(role: "system", content: content)
    }
    /// Convenience constructor for a tool-result message (Chat Completions style).
    public static func tool(callId: String, content: String) -> ChatMessage {
        .init(role: "tool", content: content, toolCallId: callId)
    }
}
