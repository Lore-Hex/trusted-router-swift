import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L7 data — configuration and option-lifting types. Wire schemas here are
// pinned by the cross-SDK parity tests and must not change.

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

/// Lift `ProviderPreferences` into a request body without clobbering caller
/// params. Shared by every endpoint that accepts a `provider:` argument.
func bodyWithProvider(
    _ params: [String: Any],
    provider: ProviderPreferences?
) -> [String: Any] {
    var body = params
    if let provider {
        body["provider"] = provider.value
    }
    return body
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
    /// Content-free client reliability telemetry (the per-attempt
    /// `x-tr-client` header). Nil applies the documented precedence:
    /// `TRUSTEDROUTER_TELEMETRY` > `DO_NOT_TRACK` > default on only for the
    /// known TrustedRouter inference and control hosts. Custom base URLs
    /// never send the header regardless of this setting.
    public var telemetry: Bool?
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
        telemetry: Bool? = nil,
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
        self.telemetry = telemetry
        self.regionalAffinity = regionalAffinity
        self.regionProbeTimeout = regionProbeTimeout
    }
}

/// Per-call overrides on top of a `TrustedRouter` client's defaults. Useful
/// for one-off API-key override, custom headers, an idempotency key, or a
/// short per-request timeout.
///
/// `apiKey`, `workspaceId`, and `idempotencyKey` are credential values the SDK
/// attaches as headers, so they are subject to credential scoping (see
/// Transport/CredentialScope.swift): on a request whose absolute URL resolves
/// to an origin outside the configured and well-known TrustedRouter API and
/// control hosts, they are withheld rather than sent. To authenticate to
/// another host deliberately, either construct a client whose `baseUrl` /
/// `controlBaseURL` is that host, or pass the header yourself in
/// `extraHeaders` — an explicitly named header is never withheld.
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
