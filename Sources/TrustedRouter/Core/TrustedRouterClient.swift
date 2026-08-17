import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L8 — CLIENT FACADE. Stored configuration plus the three public entry
// points. Zero loops, zero sleeps, zero candidate-index references live
// here: `request<T>` and `rawStreamRequest` delegate to the transport
// engine (Transport/TransportEngine.swift) through thin sendAttempt
// adapters, and `rawRequest` is single-shot by contract.

/// Thin, typed Swift client for the TrustedRouter gateway.
///
/// Construct once with a `TrustedRouterOptions`, then call any of the
/// endpoint methods declared in the `Endpoints/` extensions. All public
/// methods are `async` and throw `TrustedRouterError` for HTTP failures.
///
/// The client is `Sendable` and safe to share across actors.
public final class TrustedRouter: Sendable {
    public let apiKey: String?
    public let baseUrl: String
    public let controlBaseURL: String
    public let urlSession: URLSession
    public let defaultHeaders: [String: String]
    public let maxRetries: Int
    public let regionalFailover: Bool
    public let workspaceId: String?
    let regionalEndpointSelector: RegionalEndpointSelector?
    /// The inference hosts used when the regional selector is off: the primary
    /// followed by its alias domains.
    let aliasBaseURLs: [String]
    /// URL origins (scheme + host + effective port) that SDK-attached
    /// credential headers may be sent to: the configured bases plus every
    /// well-known TrustedRouter endpoint. See Transport/CredentialScope.swift.
    let credentialHostAllowlist: CredentialHostAllowlist

    public init(options: TrustedRouterOptions = TrustedRouterOptions()) throws {
        self.apiKey = options.apiKey
        // Strip any trailing slashes so the path-join in `requestURLString`
        // doesn't emit a double-slash URL.
        self.baseUrl = trimTrailingSlashes(options.baseUrl ?? TrustedRouterConstants.defaultAPIBaseURL)
        self.controlBaseURL = trimTrailingSlashes(options.controlBaseURL ?? TrustedRouterConstants.defaultControlBaseURL)
        self.urlSession = options.urlSession
        self.defaultHeaders = options.headers
        self.maxRetries = max(0, options.maxRetries)
        self.regionalFailover = options.regionalFailover
        self.workspaceId = options.workspaceId
        self.aliasBaseURLs = aliasFailoverURLs(
            primaryBaseURL: self.baseUrl,
            // An explicit base URL is a pin: honour it even on the default host.
            regionalFailover: options.regionalFailover && options.baseUrl == nil
        )
        self.credentialHostAllowlist = CredentialHostAllowlist(
            configuredBaseURLs: [self.baseUrl, self.controlBaseURL]
        )
        let affinityEnabled = options.regionalAffinity ?? (options.urlSession === URLSession.shared)
        if options.baseUrl == nil && options.regionalFailover && affinityEnabled {
            self.regionalEndpointSelector = RegionalEndpointSelector(
                primaryBaseURL: self.baseUrl,
                urlSession: options.urlSession,
                timeout: options.regionProbeTimeout
            )
        } else {
            self.regionalEndpointSelector = nil
        }
    }

    /// User-Agent string sent on every request. Includes the SDK version
    /// and the host OS/version so server-side logs can correlate by client.
    static var userAgent: String {
        #if os(macOS)
        let os = "macOS"
        #elseif os(iOS)
        let os = "iOS"
        #elseif os(tvOS)
        let os = "tvOS"
        #elseif os(watchOS)
        let os = "watchOS"
        #else
        let os = "Linux"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "trusted-router-swift/\(TrustedRouterConstants.version) (\(os) \(v.majorVersion).\(v.minorVersion))"
    }

    func buildHeaders(
        headers: [String: String]? = nil,
        extraHeaders: [String: String]? = nil,
        idempotencyKey: String? = nil,
        apiKey: String? = nil,
        workspaceId: String? = nil,
        includeCredentials: Bool = true
    ) -> [String: String] {
        var out = ["user-agent": TrustedRouter.userAgent]
        for (k, v) in self.defaultHeaders { out[k] = v }
        if let headers = headers {
            for (k, v) in headers { out[k] = v }
        }
        if let extraHeaders = extraHeaders {
            for (k, v) in extraHeaders { out[k] = v }
        }
        // Credential scoping (see Transport/CredentialScope.swift): the three
        // SDK-attached credential headers — `idempotency-key`,
        // `x-trustedrouter-workspace`, and the Bearer `authorization` — are
        // only injected for known TrustedRouter origins. Explicit `headers`
        // and `extraHeaders` above pass through untouched either way.
        guard includeCredentials else { return out }
        if let idempotencyKey = idempotencyKey {
            out["idempotency-key"] = idempotencyKey
        }
        if let selectedWorkspaceId = workspaceId ?? self.workspaceId {
            out["x-trustedrouter-workspace"] = selectedWorkspaceId
        }
        if let bearer = apiKey ?? self.apiKey, !bearer.isEmpty, out["authorization"] == nil {
            out["authorization"] = "Bearer \(bearer)"
        }
        return out
    }

    /// The ordered inference candidate list for one logical call: the ranked
    /// regional endpoints when the selector is on, otherwise the primary plus
    /// its alias domains.
    func inferenceBaseURLs() async -> [String] {
        guard let regionalEndpointSelector else { return aliasBaseURLs }
        return await regionalEndpointSelector.endpoints()
    }

    /// Single-shot raw request. PUBLIC AND SINGLE-SHOT BY CONTRACT: this
    /// never retries and never advances domains — callers who want retry and
    /// failover semantics use `request<T>` or `rawStreamRequest`, which ride
    /// the transport engine.
    public func rawRequest(
        method: String,
        path: String,
        headers: [String: String]? = nil,
        body: Data? = nil,
        options: PerCallOptions = PerCallOptions(),
        plane: TrustedRouterRequestPlane = .inference,
        _baseURLOverride: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let selectedBaseURL: String?
        if _baseURLOverride != nil || !usesInferenceBase(path: path, plane: plane) {
            selectedBaseURL = _baseURLOverride
        } else {
            selectedBaseURL = await inferenceBaseURLs().first
        }
        let urlString = requestURLString(
            path: path,
            plane: plane,
            baseURLOverride: selectedBaseURL
        )
        guard let url = URL(string: urlString) else {
            throw TrustedRouterError.internalError("Invalid URL: \(urlString)")
        }
        let request = buildURLRequest(
            method: method,
            url: url,
            headers: headers,
            options: options,
            body: body
        )
        let (data, response) = try await urlSession.data(for: request)
        return (data, try Self.httpOnly(response))
    }

    /// Open a byte stream with full retry/failover semantics. The platform
    /// split lives ONLY in the sendAttempt closure: Darwin opens live
    /// `AsyncBytes`; Linux buffers via `data(for:)` and replays (see
    /// Streaming/ByteStream.swift). A non-200 response is RETURNED with its
    /// stream for the caller to drain and classify.
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func rawStreamRequest(
        method: String,
        path: String,
        headers: [String: String]? = nil,
        body: Data? = nil,
        options: PerCallOptions = PerCallOptions(),
        plane: TrustedRouterRequestPlane = .inference
    ) async throws -> (TrustedRouterByteStream, HTTPURLResponse) {
        return try await withTransportRetries(
            method: method,
            path: path,
            plane: plane,
            headers: headers,
            body: body,
            options: options
        ) { request in
            #if os(Linux)
            let (data, response) = try await self.urlSession.data(for: request)
            return (Self.byteStream(from: data), try Self.httpOnly(response))
            #else
            let (bytes, response) = try await self.urlSession.bytes(for: request)
            return (Self.byteStream(from: bytes), try Self.httpOnly(response))
            #endif
        }
    }

    /// Buffered request with full retry/failover semantics, then the
    /// classify/decode tail: >=400 classifies-and-throws a typed error;
    /// success decodes `T` (or returns raw `Data` when `T == Data`).
    public func request<T: Decodable>(
        method: String,
        path: String,
        headers: [String: String]? = nil,
        body: Any? = nil,
        options: PerCallOptions = PerCallOptions(),
        plane: TrustedRouterRequestPlane = .inference
    ) async throws -> T {
        var bodyData: Data? = nil
        if let body = body {
            if let data = body as? Data {
                bodyData = data
            } else {
                bodyData = try JSONSerialization.data(withJSONObject: body)
            }
        }

        let (data, response) = try await withTransportRetries(
            method: method,
            path: path,
            plane: plane,
            headers: headers,
            body: bodyData,
            options: options
        ) { request in
            let (data, response) = try await self.urlSession.data(for: request)
            return (data, try Self.httpOnly(response))
        }

        if response.statusCode >= 400 {
            throw classifyError(statusCode: response.statusCode, data: data, response: response)
        }

        if T.self == Data.self {
            return data as! T
        }

        if data.isEmpty {
            // For Void or empty responses, we might need a better way.
            // For now we'll try to decode empty JSON.
            if let emptyObj = "{}" .data(using: .utf8) {
                return try JSONDecoder().decode(T.self, from: emptyObj)
            }
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}
