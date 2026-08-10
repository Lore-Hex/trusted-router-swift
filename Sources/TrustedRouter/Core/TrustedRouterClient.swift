import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Request routing plane for methods that need to choose between inference
/// and control/metadata hosts.
public enum TrustedRouterRequestPlane: Sendable {
    case inference
    case control
}

func trimTrailingSlashes(_ value: String) -> String {
    var trimmed = value
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed
}

/// The primary API host followed by its alias domains.
///
/// This list must have MORE THAN ONE entry or failover cannot engage at all:
/// every advance in the request loops is guarded by
/// `baseIndex < inferenceURLs.count - 1`, so a single-entry list makes the
/// transport-error and 502/503/504 handling unreachable. That was the state
/// for any client with an injected `URLSession`, which is every client that
/// configures its own caching, timeouts, or delegate — the regional selector
/// is disabled for those, and the fallback was a one-element list.
///
/// Aliases are appended only for the default API host. A caller who passed
/// their own base URL — a private deployment, a test server, a regional pin —
/// gets exactly that; silently redirecting that traffic to a public alias
/// would be worse than failing.
func aliasFailoverURLs(primaryBaseURL: String, regionalFailover: Bool) -> [String] {
    // Both sides go through the same normalization: comparing a stored base
    // URL against the raw constant is how this silently degrades to one entry.
    let primary = trimTrailingSlashes(primaryBaseURL)
    guard regionalFailover,
          primary == trimTrailingSlashes(TrustedRouterConstants.defaultAPIBaseURL)
    else { return [primary] }
    var seen = Set<String>()
    return ([primary] + TrustedRouterConstants.aliasAPIBaseURLs.map(trimTrailingSlashes))
        .filter { seen.insert($0).inserted }
}

private actor RegionalProbeRace {
    private var remaining: Int
    private var resolved = false
    private var result: String?
    private var waiter: CheckedContinuation<String?, Never>?

    init(count: Int) {
        self.remaining = count
    }

    func record(_ healthyBaseURL: String?) {
        guard !resolved else { return }
        if let healthyBaseURL {
            resolve(healthyBaseURL)
            return
        }
        remaining -= 1
        if remaining == 0 {
            resolve(nil)
        }
    }

    func firstHealthy() async -> String? {
        if resolved { return result }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    private func resolve(_ value: String?) {
        resolved = true
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}

actor RegionalEndpointSelector {
    private let primaryBaseURL: String
    private let urlSession: URLSession
    private let timeout: TimeInterval
    private var ranked: [String]?
    private var rankingTask: Task<[String], Never>?

    init(primaryBaseURL: String, urlSession: URLSession, timeout: TimeInterval) {
        self.primaryBaseURL = primaryBaseURL
        self.urlSession = urlSession
        self.timeout = max(0.1, timeout)
    }

    func endpoints() async -> [String] {
        if let ranked { return ranked }
        if let rankingTask { return await rankingTask.value }
        let task = Task { [primaryBaseURL, urlSession, timeout] in
            var seen = Set<String>()
            let candidates = (TrustedRouterConstants.regionBaseURLs + [primaryBaseURL]).filter {
                seen.insert($0).inserted
            }
            let race = RegionalProbeRace(count: candidates.count)
            for baseURL in candidates {
                Task {
                    guard let url = URL(
                        string: baseURL.replacingOccurrences(
                            of: "/v1$",
                            with: "",
                            options: .regularExpression
                        ) + "/health"
                    ) else {
                        await race.record(nil)
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = timeout
                    do {
                        let (_, response) = try await urlSession.data(for: request)
                        guard let http = response as? HTTPURLResponse,
                              http.statusCode == 200 || http.statusCode == 401
                        else {
                            await race.record(nil)
                            return
                        }
                        await race.record(baseURL)
                    } catch {
                        await race.record(nil)
                    }
                }
            }
            let winner = await race.firstHealthy()
            // No region answering is precisely when the aliases matter, so this
            // must not collapse to a single host — that would delete failover
            // at the exact moment it is needed.
            let aliases = aliasFailoverURLs(
                primaryBaseURL: primaryBaseURL, regionalFailover: true
            )
            guard let winner else { return aliases }
            seen.removeAll(keepingCapacity: true)
            return ([winner, primaryBaseURL] + candidates + aliases).filter {
                seen.insert($0).inserted
            }
        }
        rankingTask = task
        let result = await task.value
        ranked = result
        rankingTask = nil
        return result
    }
}

/// Thin, typed Swift client for the TrustedRouter gateway.
///
/// Construct once with a `TrustedRouterOptions`, then call any of the
/// endpoint methods declared in `TrustedRouter+Methods.swift`. All public
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

    public init(options: TrustedRouterOptions = TrustedRouterOptions()) throws {
        self.apiKey = options.apiKey
        // Strip any trailing slashes so the path-join in `rawRequest` doesn't
        // emit a double-slash URL.
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

    private func buildHeaders(
        headers: [String: String]? = nil,
        extraHeaders: [String: String]? = nil,
        idempotencyKey: String? = nil,
        apiKey: String? = nil,
        workspaceId: String? = nil
    ) -> [String: String] {
        var out = ["user-agent": TrustedRouter.userAgent]
        for (k, v) in self.defaultHeaders { out[k] = v }
        if let headers = headers {
            for (k, v) in headers { out[k] = v }
        }
        if let extraHeaders = extraHeaders {
            for (k, v) in extraHeaders { out[k] = v }
        }
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

    private func baseURL(for plane: TrustedRouterRequestPlane) -> String {
        switch plane {
        case .inference: return baseUrl
        case .control: return controlBaseURL
        }
    }

    private func inferenceBaseURLs() async -> [String] {
        guard let regionalEndpointSelector else { return aliasBaseURLs }
        return await regionalEndpointSelector.endpoints()
    }

    private func requestURLString(
        path: String,
        plane: TrustedRouterRequestPlane,
        baseURLOverride: String? = nil
    ) -> String {
        if let components = URLComponents(string: path), components.scheme != nil {
            return path
        }
        let relativePath = path.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        return "\(baseURLOverride ?? baseURL(for: plane))/\(relativePath)"
    }

    private func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        for candidate in [name, name.lowercased(), name.capitalized] {
            if let raw = response.allHeaderFields[candidate] as? String { return raw }
        }
        return nil
    }

    private func parseRetryAfter(_ response: HTTPURLResponse) -> Double? {
        // retry-after-ms wins when both are present: it is the more precise of
        // the two, and a server that sends it means the sub-second value.
        if let rawMs = header(response, "retry-after-ms"),
           let millis = Double(rawMs.trimmingCharacters(in: .whitespacesAndNewlines)),
           millis >= 0 {
            return millis / 1000.0
        }
        if let raw = header(response, "retry-after") {
            return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// The gateway's explicit verdict, which overrides every heuristic below.
    ///
    /// A status code cannot say whether a provider already ran. A 502 from
    /// "could not reach the provider" and a 502 from "the generation succeeded
    /// and then settlement failed" are indistinguishable here, and only the
    /// second is dangerous to re-send. Same header OpenAI's clients honour.
    ///
    /// `nil` means the server did not say, leaving behaviour unchanged for
    /// older gateways and deliberately unlabelled paths.
    private func shouldRetryVerdict(_ response: HTTPURLResponse) -> Bool? {
        guard let raw = header(response, "x-should-retry") else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Whether this response may move to a DIFFERENT domain. An explicit
    /// `x-should-retry: false` forbids it outright.
    ///
    /// That check is UNREACHABLE today and has no test, deliberately: every
    /// caller consults `shouldRetry` first, which already returns false for a
    /// labelled response. It is kept so that widening the retry set later
    /// cannot silently reintroduce domain movement on a spent response — the
    /// failure this header exists to prevent. Mutation-testing it correctly
    /// reports it as surviving. The Python SDK carries the same guard and the
    /// same note.
    private func isFailoverableStatus(_ statusCode: Int, _ response: HTTPURLResponse?) -> Bool {
        if let response, shouldRetryVerdict(response) == false { return false }
        return statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private func usesInferenceBase(path: String, plane: TrustedRouterRequestPlane) -> Bool {
        if plane != .inference {
            return false
        }
        return URLComponents(string: path)?.scheme == nil
    }

    /// Whether we may send this again — independent of WHERE it goes.
    ///
    /// This used to require `regionalFailover` for 502/503/504, so pinning to
    /// one host ALSO stopped retrying the gateway statuses entirely: one switch
    /// answering two questions. The flag now governs only the destination.
    private func shouldRetry(
        statusCode: Int,
        path: String,
        plane: TrustedRouterRequestPlane,
        response: HTTPURLResponse?
    ) -> Bool {
        if let response, let verdict = shouldRetryVerdict(response) { return verdict }
        if statusCode == 429 { return true }
        return usesInferenceBase(path: path, plane: plane) && isFailoverableStatus(statusCode, response)
    }

    /// A transport failure means no server saw the request, so re-sending is
    /// always safe; the flag only decides whether the retry may change host.
    private func shouldRetryTransportError(path: String, plane: TrustedRouterRequestPlane) -> Bool {
        return usesInferenceBase(path: path, plane: plane)
    }

    private func retrySleepMs(attempt: Int, retryAfterSeconds: Double?) -> UInt64 {
        let baseMs = min(30_000, 500 * pow(2.0, Double(attempt)))
        let jittered = Double.random(in: 0...baseMs)
        let floor = (retryAfterSeconds ?? 0) * 1000.0
        return UInt64(max(jittered, floor) * 1_000_000)
    }

    /// Package-internal entry to the error classifier, used by the streaming
    /// methods when they drain a non-200 SSE response body before throwing.
    func classifyErrorPublic(statusCode: Int, data: Data?, response: HTTPURLResponse) -> TrustedRouterError {
        classifyError(statusCode: statusCode, data: data, response: response)
    }

    private func classifyError(statusCode: Int, data: Data?, response: HTTPURLResponse) -> TrustedRouterError {
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

        let retryAfter = parseRetryAfter(response)

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

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let timeout = options.timeout {
            req.timeoutInterval = timeout
        }

        let reqHeaders = buildHeaders(
            headers: headers,
            extraHeaders: options.extraHeaders,
            idempotencyKey: options.idempotencyKey,
            apiKey: options.apiKey,
            workspaceId: options.workspaceId
        )

        for (k, v) in reqHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        
        if body != nil && req.value(forHTTPHeaderField: "Content-Type") == nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrustedRouterError.internalError("Non-HTTP response")
        }
        return (data, httpResponse)
    }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func rawStreamRequest(
        method: String,
        path: String,
        headers: [String: String]? = nil,
        body: Data? = nil,
        options: PerCallOptions = PerCallOptions(),
        plane: TrustedRouterRequestPlane = .inference
    ) async throws -> (TrustedRouterByteStream, HTTPURLResponse) {
        var effectiveOptions = options
        if usesInferenceBase(path: path, plane: plane),
           effectiveOptions.idempotencyKey == nil,
           !["GET", "HEAD", "OPTIONS"].contains(method.uppercased()) {
            effectiveOptions.idempotencyKey = "tr-req-\(UUID().uuidString)"
        }
        var attempt = 0
        var baseIndex = 0
        let inferenceURLs = usesInferenceBase(path: path, plane: plane)
            ? await inferenceBaseURLs()
            : []
        while true {
            let selectedBaseURL = inferenceURLs.isEmpty ? nil : inferenceURLs[baseIndex]
            let urlString = requestURLString(
                path: path,
                plane: plane,
                baseURLOverride: selectedBaseURL
            )
            guard let url = URL(string: urlString) else {
                throw TrustedRouterError.internalError("Invalid URL: \(urlString)")
            }

            var req = URLRequest(url: url)
            req.httpMethod = method
            req.httpBody = body
            if let timeout = effectiveOptions.timeout {
                req.timeoutInterval = timeout
            }

            let reqHeaders = buildHeaders(
                headers: headers,
                extraHeaders: effectiveOptions.extraHeaders,
                idempotencyKey: effectiveOptions.idempotencyKey,
                apiKey: effectiveOptions.apiKey,
                workspaceId: effectiveOptions.workspaceId
            )

            for (k, v) in reqHeaders {
                req.setValue(v, forHTTPHeaderField: k)
            }

            if body != nil && req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            do {
                #if os(Linux)
                let (data, response) = try await urlSession.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TrustedRouterError.internalError("Non-HTTP response")
                }
                if attempt < maxRetries && shouldRetry(statusCode: httpResponse.statusCode, path: path, plane: plane, response: httpResponse) {
                    let retryAfter = parseRetryAfter(httpResponse)
                    if regionalFailover, isFailoverableStatus(httpResponse.statusCode, httpResponse),
                       baseIndex < inferenceURLs.count - 1 {
                        baseIndex += 1
                    }
                    try await Task.sleep(nanoseconds: retrySleepMs(attempt: attempt, retryAfterSeconds: retryAfter))
                    attempt += 1
                    continue
                }
                return (Self.byteStream(from: data), httpResponse)
                #else
                let (bytes, response) = try await urlSession.bytes(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TrustedRouterError.internalError("Non-HTTP response")
                }
                if attempt < maxRetries && shouldRetry(statusCode: httpResponse.statusCode, path: path, plane: plane, response: httpResponse) {
                    let retryAfter = parseRetryAfter(httpResponse)
                    if regionalFailover, isFailoverableStatus(httpResponse.statusCode, httpResponse),
                       baseIndex < inferenceURLs.count - 1 {
                        baseIndex += 1
                    }
                    try await Task.sleep(nanoseconds: retrySleepMs(attempt: attempt, retryAfterSeconds: retryAfter))
                    attempt += 1
                    continue
                }
                return (Self.byteStream(from: bytes), httpResponse)
                #endif
            } catch let err as TrustedRouterError {
                throw err
            } catch {
                if attempt >= maxRetries || !shouldRetryTransportError(path: path, plane: plane) {
                    throw TrustedRouterError.internalError(error.localizedDescription)
                }
                if regionalFailover, baseIndex < inferenceURLs.count - 1 { baseIndex += 1 }
                try await Task.sleep(nanoseconds: retrySleepMs(attempt: attempt, retryAfterSeconds: nil))
                attempt += 1
            }
        }
    }

    private static func byteStream(from data: Data) -> TrustedRouterByteStream {
        TrustedRouterByteStream { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    #if !os(Linux)
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    private static func byteStream(from bytes: URLSession.AsyncBytes) -> TrustedRouterByteStream {
        TrustedRouterByteStream { continuation in
            Task {
                do {
                    for try await byte in bytes {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    #endif

    public func request<T: Decodable>(
        method: String,
        path: String,
        headers: [String: String]? = nil,
        body: Any? = nil,
        options: PerCallOptions = PerCallOptions(),
        plane: TrustedRouterRequestPlane = .inference
    ) async throws -> T {
        var effectiveOptions = options
        if usesInferenceBase(path: path, plane: plane),
           effectiveOptions.idempotencyKey == nil,
           !["GET", "HEAD", "OPTIONS"].contains(method.uppercased()) {
            effectiveOptions.idempotencyKey = "tr-req-\(UUID().uuidString)"
        }
        var bodyData: Data? = nil
        if let body = body {
            if let data = body as? Data {
                bodyData = data
            } else {
                bodyData = try JSONSerialization.data(withJSONObject: body)
            }
        }

        var attempt = 0
        var baseIndex = 0
        let inferenceURLs = usesInferenceBase(path: path, plane: plane)
            ? await inferenceBaseURLs()
            : []
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await rawRequest(
                    method: method,
                    path: path,
                    headers: headers,
                    body: bodyData,
                    options: effectiveOptions,
                    plane: plane,
                    _baseURLOverride: inferenceURLs.isEmpty ? nil : inferenceURLs[baseIndex]
                )
            } catch let err as TrustedRouterError {
                throw err
            } catch {
                if attempt >= maxRetries || !shouldRetryTransportError(path: path, plane: plane) {
                    throw TrustedRouterError.internalError(error.localizedDescription)
                }
                if regionalFailover, baseIndex < inferenceURLs.count - 1 { baseIndex += 1 }
                try await Task.sleep(nanoseconds: retrySleepMs(attempt: attempt, retryAfterSeconds: nil))
                attempt += 1
                continue
            }

            if response.statusCode >= 400 {
                if attempt < maxRetries && shouldRetry(statusCode: response.statusCode, path: path, plane: plane, response: response) {
                    let retryAfter = parseRetryAfter(response)
                    if regionalFailover, isFailoverableStatus(response.statusCode, response),
                       baseIndex < inferenceURLs.count - 1 {
                        baseIndex += 1
                    }
                    try await Task.sleep(nanoseconds: retrySleepMs(attempt: attempt, retryAfterSeconds: retryAfter))
                    attempt += 1
                    continue
                }

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
}
