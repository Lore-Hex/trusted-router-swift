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

private actor RegionalEndpointSelector {
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
            guard let winner else { return [primaryBaseURL] }
            seen.removeAll(keepingCapacity: true)
            return ([winner, primaryBaseURL] + candidates).filter {
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
    private let regionalEndpointSelector: RegionalEndpointSelector?

    public init(options: TrustedRouterOptions = TrustedRouterOptions()) throws {
        func trimTrailingSlashes(_ value: String) -> String {
            var trimmed = value
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }

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
        guard let regionalEndpointSelector else { return [baseUrl] }
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

    private func parseRetryAfter(_ response: HTTPURLResponse) -> Double? {
        if let raw = response.allHeaderFields["retry-after"] as? String ?? response.allHeaderFields["Retry-After"] as? String {
            return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func isFailoverableStatus(_ statusCode: Int) -> Bool {
        return statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private func usesInferenceBase(path: String, plane: TrustedRouterRequestPlane) -> Bool {
        if plane != .inference {
            return false
        }
        return URLComponents(string: path)?.scheme == nil
    }

    private func shouldRetry(statusCode: Int, path: String, plane: TrustedRouterRequestPlane) -> Bool {
        if statusCode == 429 {
            return true
        }
        return regionalFailover && usesInferenceBase(path: path, plane: plane) && isFailoverableStatus(statusCode)
    }

    private func shouldRetryTransportError(path: String, plane: TrustedRouterRequestPlane) -> Bool {
        return regionalFailover && usesInferenceBase(path: path, plane: plane)
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
                if attempt < maxRetries && shouldRetry(statusCode: httpResponse.statusCode, path: path, plane: plane) {
                    let retryAfter = parseRetryAfter(httpResponse)
                    if isFailoverableStatus(httpResponse.statusCode), baseIndex < inferenceURLs.count - 1 {
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
                if attempt < maxRetries && shouldRetry(statusCode: httpResponse.statusCode, path: path, plane: plane) {
                    let retryAfter = parseRetryAfter(httpResponse)
                    if isFailoverableStatus(httpResponse.statusCode), baseIndex < inferenceURLs.count - 1 {
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
                if baseIndex < inferenceURLs.count - 1 { baseIndex += 1 }
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
                if baseIndex < inferenceURLs.count - 1 { baseIndex += 1 }
                try await Task.sleep(nanoseconds: retrySleepMs(attempt: attempt, retryAfterSeconds: nil))
                attempt += 1
                continue
            }

            if response.statusCode >= 400 {
                if attempt < maxRetries && shouldRetry(statusCode: response.statusCode, path: path, plane: plane) {
                    let retryAfter = parseRetryAfter(response)
                    if isFailoverableStatus(response.statusCode), baseIndex < inferenceURLs.count - 1 {
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
