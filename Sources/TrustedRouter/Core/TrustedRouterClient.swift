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
    let credentialFreeURLSession: URLSession
    public let defaultHeaders: [String: String]
    public let maxRetries: Int
    public let regionalFailover: Bool
    /// Whether this client emits the content-free `x-tr-client` reliability
    /// header (client-telemetry contract v1 §6.3). Resolved once at
    /// construction: explicit option > `TRUSTEDROUTER_TELEMETRY` >
    /// `DO_NOT_TRACK` > default on only for known TrustedRouter hosts.
    public let telemetryEnabled: Bool
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
        // x-tr-client is SDK-RESERVED (client-telemetry contract v1 §6.1): only
        // the SDK's own recorder may set a value, on every path. Every header
        // layer the SDK merges is stripped in `buildHeaders`; an injected
        // session's `httpAdditionalHeaders` is the one layer it cannot reach,
        // because the URL loading system merges that after the request leaves
        // the SDK, for exactly the fields the request does not set. Left alone,
        // such a value would ride every request the SDK deliberately does NOT
        // describe — opted out, control plane, custom base, absolute URL,
        // `rawRequest` — silently defeating telemetry opt-out and attributing a
        // caller's forgery to this SDK. There is no request-level way to mark a
        // field absent, so the session is refused here instead: a loud
        // configuration error at construction, once, rather than a silent
        // forgery on every call. Narrow by design — any other default header on
        // the session is untouched.
        if let reservedName = ClientTelemetry.reservedHeaderInSessionDefaults(options.urlSession) {
            throw TrustedRouterError.internalError(
                "The URLSession passed to TrustedRouter sets the SDK-reserved header "
                + "'\(reservedName)' in URLSessionConfiguration.httpAdditionalHeaders. "
                + "That header is set only by the SDK's own telemetry recorder "
                + "(client-telemetry contract v1 §6.1) and cannot be stripped from a "
                + "session default, so this configuration is refused. Remove it from "
                + "httpAdditionalHeaders; to disable client telemetry use "
                + "TrustedRouterOptions.telemetry = false, TRUSTEDROUTER_TELEMETRY=0, "
                + "or DO_NOT_TRACK=1."
            )
        }
        self.apiKey = options.apiKey
        // Strip any trailing slashes so the path-join in `requestURLString`
        // doesn't emit a double-slash URL.
        self.baseUrl = trimTrailingSlashes(options.baseUrl ?? TrustedRouterConstants.defaultAPIBaseURL)
        self.controlBaseURL = trimTrailingSlashes(options.controlBaseURL ?? TrustedRouterConstants.defaultControlBaseURL)
        self.urlSession = options.urlSession
        self.credentialFreeURLSession = options.urlSession.trustedRouterCredentialFreeCopy()
        self.defaultHeaders = options.headers
        self.maxRetries = max(0, options.maxRetries)
        self.regionalFailover = options.regionalFailover
        self.telemetryEnabled = ClientTelemetry.resolveEnabled(
            explicit: options.telemetry,
            baseURL: self.baseUrl,
            controlBaseURL: self.controlBaseURL,
            environment: ProcessInfo.processInfo.environment
        )
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
    ///
    /// The shape is pinned by the client-telemetry contract (§3.1): the
    /// enclave parses `trusted-router-swift/SEMVER( runtime/ver)?` with the
    /// runtime token matching `[a-z]{1,10}/[0-9A-Za-z.+-]{1,24}`. The old
    /// parenthesised `(macOS 14.6)` suffix fell outside that grammar, so the
    /// runtime was dropped server-side; `macos/14.6.1` carries the same
    /// information inside it.
    static var userAgent: String {
        #if os(macOS)
        let os = "macos"
        #elseif os(iOS)
        let os = "ios"
        #elseif os(tvOS)
        let os = "tvos"
        #elseif os(watchOS)
        let os = "watchos"
        #else
        let os = "linux"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "trusted-router-swift/\(TrustedRouterConstants.version) "
            + "\(os)/\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Case-insensitively set `name` to `value` in a header dictionary.
    ///
    /// HTTP header names are case-insensitive but `[String: String]` is not:
    /// a plain subscript write can leave `user-agent` AND `User-Agent` side
    /// by side, and because `URLRequest`'s own header store IS
    /// case-insensitive, whichever entry dictionary iteration happens to
    /// apply last silently wins. Removing every case-variant before writing
    /// makes the last LAYER to set a name the deterministic winner. The
    /// merged dictionary keeps the winning layer's spelling (the URL loading
    /// system may still canonicalize casing on the wire). Layers are applied
    /// in sorted key order, so even two case-variants inside ONE dictionary
    /// resolve deterministically: the lexicographically last key's value
    /// wins.
    private static func setHeader(
        _ headers: inout [String: String], name: String, value: String
    ) {
        removeHeader(&headers, name: name)
        headers[name] = value
    }

    /// Remove every case-variant of `name`. The write half of `setHeader`
    /// without the write — the one place case-insensitive removal lives, so
    /// credential scoping and reserved-header stripping do not each carry
    /// their own hand-rolled `lowercased()` match.
    private static func removeHeader(
        _ headers: inout [String: String], name: String
    ) {
        let target = name.lowercased()
        for key in headers.keys where key.lowercased() == target {
            headers.removeValue(forKey: key)
        }
    }

    /// Case-insensitive lookup companion to `setHeader`.
    private static func headerValue(
        _ headers: [String: String], _ name: String
    ) -> String? {
        let target = name.lowercased()
        for (key, value) in headers where key.lowercased() == target {
            return value
        }
        return nil
    }

    /// Merge the header layers for one request. Later layers win, whatever
    /// their casing: built-in `user-agent` < client `defaultHeaders` <
    /// per-call `headers` < `extraHeaders` < computed idempotency/workspace.
    /// The computed `authorization` is the one exception: it fills in from
    /// the API key only when NO earlier layer supplied an authorization
    /// header in any casing.
    func buildHeaders(
        headers: [String: String]? = nil,
        extraHeaders: [String: String]? = nil,
        idempotencyKey: String? = nil,
        apiKey: String? = nil,
        workspaceId: String? = nil,
        includeCredentials: Bool = true,
        telemetryHeaderValue: String? = nil
    ) -> [String: String] {
        // Each layer applies in sorted key order: dictionary iteration order
        // is seeded per process, and letting it pick the survivor among
        // same-layer case-variants would reintroduce (rarer) nondeterminism.
        var out = ["user-agent": TrustedRouter.userAgent]
        for (k, v) in self.defaultHeaders.sorted(by: { $0.key < $1.key }) {
            Self.setHeader(&out, name: k, value: v)
        }
        // Credential scoping, part 1 (see Transport/CredentialScope.swift):
        // client-wide default headers are configured once, for the client's
        // own hosts — they are not authorization to credential whatever
        // origin a caller-supplied absolute URL happens to name. The strip
        // is case-insensitive because HTTP header names are; that now comes
        // from the shared header container (`removeHeader`) rather than a
        // second hand-rolled match. Iteration order over the name set is
        // irrelevant: removing distinct header names commutes.
        if !includeCredentials {
            for name in TrustedRouter.credentialHeaderNames {
                Self.removeHeader(&out, name: name)
            }
        }
        // Explicit per-call headers are the caller naming a value alongside
        // the URL they are naming, so they pass through untouched on every
        // origin. Callers who must authenticate to a host the client is not
        // configured for use these (or construct a client with that base).
        if let headers = headers {
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
                Self.setHeader(&out, name: k, value: v)
            }
        }
        if let extraHeaders = extraHeaders {
            for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) {
                Self.setHeader(&out, name: k, value: v)
            }
        }
        // x-tr-client assembly (client-telemetry contract v1 §6.1: this is
        // the swift header-assembly site). The header is SDK-RESERVED:
        // caller-supplied values are stripped in every case-variant on EVERY
        // path — opted-out, control-plane, custom-base, out-of-scope origin,
        // and `rawRequest` included — so a stale or forged value can never
        // ride a request the SDK decided not to describe. (Ruled stronger
        // than the py reference, whose stripping is recorder-scoped.) Only
        // the engine's recorder may put a value here.
        //
        // It sits ABOVE the credential-scoping return below, deliberately:
        // that return is taken for exactly the out-of-scope origins a forged
        // value would most want to ride, so a strip placed after it would
        // leave one path unsanitised. Stripping is unconditional; only the
        // SET is conditional on an active recorder. Case-insensitivity comes
        // from the shared header container, so this name needs no
        // hand-rolled matching of its own.
        //
        // "EVERY path" is literal, and this strip is only half of how it is
        // kept. It covers the three layers the SDK merges: `defaultHeaders`,
        // per-call `headers:`, and `options.extraHeaders`. The fourth layer —
        // an injected session's `URLSessionConfiguration.httpAdditionalHeaders`
        // — is merged by the URL loading system AFTER the request leaves this
        // function, for exactly the fields the request does not set, and no
        // request-level value can mark a field absent. That layer is therefore
        // closed at the other end: `init` refuses a session whose default
        // headers name this field at all. Unlike the credential headers, whose
        // §-documented boundary really does stop at the SDK's own layers, this
        // one has no reachable exception.
        Self.removeHeader(&out, name: ClientTelemetry.reservedHeaderName)
        if let telemetryHeaderValue {
            Self.setHeader(
                &out, name: ClientTelemetry.reservedHeaderName, value: telemetryHeaderValue
            )
        }
        // Credential scoping, part 2: the three headers the SDK attaches from
        // its own stored configuration — `idempotency-key`,
        // `x-trustedrouter-workspace`, and the Bearer `authorization` — are
        // only injected for in-scope origins.
        guard includeCredentials else { return out }
        if let idempotencyKey = idempotencyKey {
            Self.setHeader(&out, name: "idempotency-key", value: idempotencyKey)
        }
        if let selectedWorkspaceId = workspaceId ?? self.workspaceId {
            Self.setHeader(&out, name: "x-trustedrouter-workspace", value: selectedWorkspaceId)
        }
        if let bearer = apiKey ?? self.apiKey, !bearer.isEmpty,
           Self.headerValue(out, "authorization") == nil {
            Self.setHeader(&out, name: "authorization", value: "Bearer \(bearer)")
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
        let (data, response) = try await urlSession.trustedRouterData(for: request)
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
            options: options,
            streaming: true
        ) { request in
            #if os(Linux)
            let (data, response) = try await self.urlSession.trustedRouterData(for: request)
            return (Self.byteStream(from: data), try Self.httpOnly(response))
            #else
            let (bytes, response) = try await self.urlSession.trustedRouterBytes(for: request)
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
            options: options,
            streaming: false
        ) { request in
            let (data, response) = try await self.urlSession.trustedRouterData(for: request)
            return (data, try Self.httpOnly(response))
        }

        if !(200..<300).contains(response.statusCode) {
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
