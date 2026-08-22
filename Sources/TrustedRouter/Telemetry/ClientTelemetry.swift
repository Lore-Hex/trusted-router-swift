import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// L7 data + L1 policy — client-observed reliability telemetry contract v1.
// This file owns the header channel and request recorder; BeaconReporter.swift
// owns the bounded out-of-engine client-events delivery channel.
// (Lore-Hex/quill-router): the per-attempt `x-tr-client` header (§3.2), the
// closed host/endpoint/outcome/error-class vocabularies (§5.2), transport
// error classification, and the enable/disable precedence (§6.3).
// `rawRequest` remains the out-of-engine single-shot precedent: beacon sends
// use the same one-attempt shape on their own URLSession, never the engine.
//
// PRINCIPLES (§2, non-negotiable):
//  - Content-free by construction: every emitted value is a closed enum or a
//    clamped integer; an out-of-grammar or over-length header sends NOTHING.
//  - Never on the money path: nothing in this file throws, traps, or fails a
//    request. No force-unwraps; every Double→Int conversion is clamped and
//    finite-checked first (`UInt64(someDouble)` trapping on a header-supplied
//    infinity is exactly how this SDK once crashed — see RetryPolicy).
//  - This file depends only on Foundation and Core/Constants.swift so it
//    compiles standalone (the local toolchain cannot link SwiftPM; the
//    verification harness compiles these two files directly).

/// Contract v1 vocabulary and pure helpers for the client telemetry header.
/// Pinned by `SDKParityContractTests` — these raw values are the cross-SDK
/// wire vocabulary and must not change without a coordinated release.
enum ClientTelemetry {

    // MARK: - Parity constants (§6.4: pinned for the later beacon PR)

    static let schemaVersion = 1
    static let beaconPath = "/client-events"

    /// The SDK-reserved header name (§6.1). Only an active recorder may set a
    /// value for it, on every path.
    static let reservedHeaderName = "x-tr-client"

    /// The reserved field name present in an injected session's default
    /// headers, in the caller's own spelling, or nil when there is none.
    ///
    /// `URLSessionConfiguration.httpAdditionalHeaders` is the one header layer
    /// the SDK cannot strip: the URL loading system merges it AFTER the request
    /// leaves `buildHeaders`, for exactly the field names the request does not
    /// set, and there is no request-level way to mark a field explicitly absent
    /// (the only suppressing value is an empty one, which would put a bare
    /// `x-tr-client:` on every excluded request and break §6.3 opt-out). So a
    /// session carrying the reserved field is refused at construction instead —
    /// see `TrustedRouter.init`. Matched case-insensitively, and only `String`
    /// keys can name an HTTP field.
    static func reservedHeaderInSessionDefaults(_ session: URLSession) -> String? {
        guard let additionalHeaders = session.configuration.httpAdditionalHeaders else {
            return nil
        }
        for key in additionalHeaders.keys {
            guard let name = key as? String else { continue }
            if name.lowercased() == reservedHeaderName { return name }
        }
        return nil
    }

    /// Host enum (§5.2).
    static let hosts: [String] = [
        "apex",
        "ally",
        "uptime",
        "us_central1",
        "us_east4",
        "europe_west4",
        "control",
        "custom"
    ]

    /// Endpoint enum (§5.2).
    static let endpoints: [String] = [
        "chat_completions",
        "messages",
        "responses",
        "embeddings",
        "images",
        "videos",
        "models",
        "fusion",
        "control_other",
        "inference_other"
    ]

    /// Outcome enum (§5.2).
    static let outcomes: [String] = [
        "ok",
        "http_error",
        "transport_error",
        "timeout",
        "stream_broken",
        "aborted"
    ]

    /// FinalOutcome enum (§5.2).
    static let finalOutcomes: [String] = outcomes + ["exhausted"]

    /// ErrorClass enum (§5.2).
    static let errorClasses: [String] = [
        "dns",
        "tls",
        "connect_refused",
        "connect_timeout",
        "connect_error",
        "read_timeout",
        "write_timeout",
        "pool_timeout",
        "protocol_error",
        "reset",
        "io_error",
        "proxy_error",
        "stream_stalled",
        "unknown"
    ]

    /// Durations on the wire are clamped into `0...maxDurationMs` (§3.2).
    static let maxDurationMs = 3_600_000

    /// Whole-header byte budget (§3.2): above this, send nothing.
    static let maxHeaderBytes = 160

    // MARK: - Host mapping (§5.2)

    /// Lowercased `(scheme, host)` of a URL, or nil when either is absent.
    /// Mirrors py `_scheme_host`: an unparseable URL classifies as custom,
    /// never throws.
    static func schemeHost(_ url: String) -> (scheme: String, host: String)? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return (scheme, host)
    }

    /// True for `https://trustedrouter.com` or any subdomain — the only
    /// control plane telemetry may default on for (§6.3).
    static func isControlHost(_ url: String) -> Bool {
        guard let (scheme, host) = schemeHost(url) else { return false }
        return scheme == "https"
            && (host == "trustedrouter.com" || host.hasSuffix(".trustedrouter.com"))
    }

    /// Map a base URL to the closed Host vocabulary (§5.2). Scheme AND host
    /// must match the pinned constant (an `http://` apex is custom, exactly
    /// as in the Python SDK); anything unrecognised is `custom`.
    static func hostEnum(_ baseURL: String) -> String {
        guard let pair = schemeHost(baseURL) else { return "custom" }
        if matches(pair, TrustedRouterConstants.defaultAPIBaseURL) { return "apex" }
        for (aliasURL, name) in zip(TrustedRouterConstants.aliasAPIBaseURLs, ["ally", "uptime"]) {
            if matches(pair, aliasURL) { return name }
        }
        let regions = ["us_central1", "us_east4", "europe_west4"]
        for (regionURL, name) in zip(TrustedRouterConstants.regionBaseURLs, regions) {
            if matches(pair, regionURL) { return name }
        }
        if matches(pair, TrustedRouterConstants.defaultControlBaseURL) || isControlHost(baseURL) {
            return "control"
        }
        return "custom"
    }

    private static func matches(_ pair: (scheme: String, host: String), _ constant: String) -> Bool {
        guard let other = schemeHost(constant) else { return false }
        return pair.scheme == other.scheme && pair.host == other.host
    }

    // MARK: - Enable/disable resolution (§6.3)

    /// Opt-out precedence, mirroring py `resolve_telemetry_enabled`:
    /// explicit argument > `TRUSTEDROUTER_TELEMETRY` > `DO_NOT_TRACK` >
    /// default (on only when the inference base is a known TrustedRouter host
    /// AND the control host is https trustedrouter.com or a subdomain).
    /// The environment is an injected dictionary so tests never mutate
    /// process state; callers pass `ProcessInfo.processInfo.environment`.
    static func resolveEnabled(
        explicit: Bool?,
        baseURL: String,
        controlBaseURL: String,
        environment: [String: String]
    ) -> Bool {
        if let explicit { return explicit }
        let configured = (environment["TRUSTEDROUTER_TELEMETRY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["0", "false", "off", "no"].contains(configured) { return false }
        if ["1", "true", "on", "yes"].contains(configured) { return true }
        if (environment["DO_NOT_TRACK"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return false
        }
        return hostEnum(baseURL) != "custom" && isControlHost(controlBaseURL)
    }

    // MARK: - Transport error classification (§5.2 ErrorClass)

    /// The error and up to five underlying errors, cycle-safe. Mirrors py
    /// `_exception_chain` walking `__cause__`/`__context__`.
    static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let nsError = current, chain.count < 6 {
            if chain.contains(where: { $0 === nsError }) { break }
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// True only when the error ITSELF is a timeout (the outcome decision),
    /// mirroring py's top-level `isinstance(exc, httpx.TimeoutException)` —
    /// a timeout buried in the underlying chain still classifies as
    /// `pc=connect_timeout` but records outcome `transport_error`, which is
    /// exactly the combination in the contract's §3.2 retry example.
    static func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.timedOut.rawValue
    }

    /// Map a thrown transport error to the closed ErrorClass vocabulary
    /// (§5.2). Must be called at the transport engine's bare `catch`, BEFORE
    /// the flatten to `TrustedRouterError.internalError(localizedDescription)`
    /// discards everything but a message string (§6.1).
    ///
    /// URLSession does not expose the timeout phase the way httpx does:
    /// ConnectTimeout and ReadTimeout are one `.timedOut`, and a failed
    /// `data(for:)`/`bytes(for:)` surfaces no response/body state, so at the
    /// engine's emit point `responseOpened` is always false. The split is
    /// therefore best-effort BY DESIGN: a pre-response `.timedOut` — which
    /// may genuinely be either a connect stall or a first-byte stall —
    /// classifies as `connect_timeout`, a documented approximation (the
    /// closed ErrorClass vocabulary has no phase-free timeout value, and
    /// discarding the timeout signal as `unknown` would lose more than the
    /// occasional misattributed phase). `responseOpened: true` exists for
    /// callers that do know headers arrived (the later beacon PR's
    /// stream-error path), yielding `read_timeout`.
    static func classifyTransportError(_ error: Error, responseOpened: Bool = false) -> String {
        let chain = errorChain(error)

        func inChain(urlCodes: Set<Int>) -> Bool {
            chain.contains { $0.domain == NSURLErrorDomain && urlCodes.contains($0.code) }
        }
        func inChain(posixCodes: Set<Int>) -> Bool {
            chain.contains { $0.domain == NSPOSIXErrorDomain && posixCodes.contains($0.code) }
        }

        if inChain(urlCodes: [URLError.timedOut.rawValue])
            || inChain(posixCodes: [Int(ETIMEDOUT)]) {
            return responseOpened ? "read_timeout" : "connect_timeout"
        }
        var tlsCodes: Set<Int> = [
            URLError.secureConnectionFailed.rawValue,
            URLError.serverCertificateHasBadDate.rawValue,
            URLError.serverCertificateUntrusted.rawValue,
            URLError.serverCertificateHasUnknownRoot.rawValue,
            URLError.serverCertificateNotYetValid.rawValue,
            URLError.clientCertificateRejected.rawValue,
            URLError.clientCertificateRequired.rawValue
        ]
        #if !canImport(FoundationNetworking)
        // App Transport Security is Darwin-only; the FoundationNetworking
        // URLError has no such member.
        tlsCodes.insert(URLError.appTransportSecurityRequiresSecureConnection.rawValue)
        #endif
        if inChain(urlCodes: tlsCodes) {
            return "tls"
        }
        if inChain(urlCodes: [
            URLError.cannotFindHost.rawValue,
            URLError.dnsLookupFailed.rawValue
        ]) {
            return "dns"
        }
        // POSIX detail outranks the coarse URLError bucket:
        // `.cannotConnectToHost` covers refused, unreachable, and more, but
        // when the underlying errno survives in the chain it says WHICH —
        // ECONNREFUSED is a live host refusing (connect_refused), while an
        // unreachable host or network is connect_error. Bare
        // `.cannotConnectToHost` with no errno is an UNPROVEN connect
        // failure and classifies connect_error, matching go/js/py where
        // connect_refused is reserved for a proven refusal syscall —
        // per-class distributions stay comparable across SDKs (both classes
        // are tr_fault-equivalent under §8 either way).
        if inChain(posixCodes: [Int(ECONNREFUSED)]) {
            return "connect_refused"
        }
        // A proven reset outranks the coarse connect bucket too, and for the
        // same reason refusal does. Darwin reports a mid-connect reset as
        // `.cannotConnectToHost` wrapping ECONNRESET, so testing the coarse
        // bucket first would bury the specific signal — py orders
        // ConnectionRefusedError, then ConnectionResetError, then
        // httpx.ConnectError, and `pc` has to agree across SDKs or the
        // per-class distributions stop being comparable.
        if inChain(urlCodes: [URLError.networkConnectionLost.rawValue])
            || inChain(posixCodes: [Int(ECONNRESET)]) {
            return "reset"
        }
        // Unreachable host/network and a bare `.cannotConnectToHost` are both
        // connect_error — py has no unreachable-specific branch, so these
        // fall through its `httpx.ConnectError` arm to the same class.
        if inChain(posixCodes: [Int(EHOSTUNREACH), Int(ENETUNREACH)]) {
            return "connect_error"
        }
        if inChain(urlCodes: [URLError.cannotConnectToHost.rawValue]) {
            return "connect_error"
        }
        if inChain(urlCodes: [
            URLError.badServerResponse.rawValue,
            URLError.cannotParseResponse.rawValue,
            URLError.httpTooManyRedirects.rawValue,
            URLError.redirectToNonExistentLocation.rawValue
        ]) {
            return "protocol_error"
        }
        if inChain(posixCodes: [Int(EPIPE), Int(EIO)]) {
            return "io_error"
        }
        return "unknown"
    }

    // MARK: - Clamped conversions (never trap; §2.2)

    /// Seconds → whole milliseconds clamped into `0...maxDurationMs`.
    /// NaN/±infinity → 0. The range check happens on the Double BEFORE the
    /// `Int(_:)` conversion, which would otherwise trap on out-of-range input.
    static func clampedMilliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let milliseconds = seconds * 1000.0
        guard milliseconds > 0 else { return 0 }
        guard milliseconds < Double(maxDurationMs) else { return maxDurationMs }
        return Int(milliseconds)
    }

    // MARK: - Header assembly (§3.2)

    /// `value = [a-z0-9_]{1,24}`, checked without a regex allocation.
    static func isValidHeaderValue(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 24 else { return false }
        return scalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    /// Join `key=value` pairs with `;` and apply the §3.2 guards: ≤160 bytes
    /// and every value matching `^[a-z0-9_]{1,24}$`. Everything is bounded by
    /// construction upstream, but telemetry may never fail a request — so an
    /// out-of-grammar value returns nil and the attempt sends no header.
    static func assembleHeaderLine(_ pairs: [(key: String, value: String)]) -> String? {
        let header = pairs.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        guard header.utf8.count <= maxHeaderBytes,
              pairs.allSatisfy({ isValidHeaderValue($0.value) })
        else { return nil }
        return header
    }
}

/// Records the per-attempt facts of ONE logical inference call as the
/// transport engine drives it, and derives each attempt's `x-tr-client`
/// header. Mirrors the py `RequestRecorder`
/// begin_attempt / on_response / on_transport_error / on_moved /
/// header_value flow. Created once per `withTransportRetries` call and
/// touched only by that task; no locking needed.
final class RequestRecorder: @unchecked Sendable {

    struct Attempt {
        var index: Int
        var host: String
        var outcome: String
        var httpStatus: Int?
        var errorClass: String?
        var errorSource: String?
        var shouldRetry: Bool?
        var retryAfterMs: Int?
        var elapsedMs: Int
        var ttfbMs: Int?
        var requestID: String?
        var moved: Bool
    }

    /// §3.2: `po` describes the previous FAILURE and its vocabulary is
    /// `none | http_error | transport_error | timeout | stream_broken` —
    /// deliberately excluding `ok` and `aborted`. A verdict-forced retry
    /// (`x-should-retry: true` on a 2xx) really does produce a previous
    /// attempt whose outcome is `ok`; emitting `po=ok` would be out of
    /// vocabulary and the enclave drops the WHOLE header for it (the py
    /// reference currently has that latent bug — ruled not to replicate).
    /// Outcomes outside this set map to `none`.
    private static let previousOutcomeVocabulary: Set<String> = [
        "http_error", "transport_error", "timeout", "stream_broken"
    ]

    let streaming: Bool
    private let now: () -> Double
    private let reporter: TelemetryReporter?
    private let endpoint: String
    private let method: String
    private let providerPinned: Bool
    private let model: String?
    private let configuredTimeout: Double?
    private(set) var attempts: [Attempt] = []
    private(set) var failoverUsed = false
    private(set) var ttftMs: Int?
    private var attemptPhases: [String] = []
    private var firstStarted: Double?
    private var attemptStarted: Double?
    private var currentHost: String?
    private var currentIndex: Int?
    private var finished = false
    private var exhaustedHint = false

    /// `now` is a monotonic seconds clock, injectable for deterministic
    /// tests (mirroring py's use of `time.perf_counter`).
    init(
        streaming: Bool,
        reporter: TelemetryReporter? = nil,
        endpoint: String = "inference_other",
        method: String = "POST",
        providerPinned: Bool = false,
        model: String? = nil,
        configuredTimeout: Double? = nil,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.streaming = streaming
        self.reporter = reporter
        self.endpoint = ClientTelemetry.endpoints.contains(endpoint) ? endpoint : "inference_other"
        self.method = method.uppercased()
        self.providerPinned = providerPinned
        self.model = ClientTelemetry.validModel(model)
        self.configuredTimeout = configuredTimeout
        self.now = now
    }

    /// Call at the top of every engine iteration, before the request is
    /// built, with the base URL this attempt will hit.
    func beginAttempt(baseURL: String) {
        let started = now()
        if firstStarted == nil { firstStarted = started }
        attemptStarted = started
        currentHost = ClientTelemetry.hostEnum(baseURL)
        currentIndex = attempts.count
    }

    /// The `x-tr-client` value for the current attempt, or nil when nothing
    /// may be sent. Key order is fixed by §3.2: `v,a[,po,pc,ph,pm,sm],s[,fo]`
    /// — the retry-context keys and `fo` appear only when the attempt index
    /// is greater than zero. Never sent for a custom host (§3.2: a
    /// self-hosted gateway is not TrustedRouter's to measure).
    func headerValue() -> String? {
        guard let index = currentIndex, let host = currentHost, host != "custom" else {
            return nil
        }
        // The contract bounds `a` to 0..99 (§3.2). An index past that cannot
        // be represented, so the attempt sends nothing — never a value the
        // enclave would drop the whole header for. (Unreachable through the
        // engine, whose retries are capped far below 99.)
        guard index <= 99 else { return nil }
        var pairs: [(key: String, value: String)] = [("v", "1"), ("a", String(index))]
        if index > 0 {
            guard let previous = attempts.last else { return nil }
            let firstStarted = self.firstStarted ?? attemptStarted ?? now()
            let sinceFirstMs = ClientTelemetry.clampedMilliseconds(
                (attemptStarted ?? firstStarted) - firstStarted
            )
            let previousOutcome = Self.previousOutcomeVocabulary.contains(previous.outcome)
                ? previous.outcome
                : "none"
            pairs.append(("po", previousOutcome))
            pairs.append(("pc", previousOutcome == "none" ? "none" : previous.errorClass ?? "none"))
            pairs.append(("ph", previous.host))
            pairs.append(("pm", String(previous.elapsedMs)))
            pairs.append(("sm", String(sinceFirstMs)))
        }
        pairs.append(("s", streaming ? "1" : "0"))
        if index > 0 {
            pairs.append(("fo", failoverUsed ? "1" : "0"))
        }
        return ClientTelemetry.assembleHeaderLine(pairs)
    }

    /// Record an attempt that produced an HTTP response (any status).
    func onResponse(statusCode: Int) {
        onResponse(statusCode: statusCode, response: nil, body: nil)
    }

    /// Record response headers at TTFB. The body is inspected only for the
    /// closed error-source enum; no response text is retained.
    func onResponse(statusCode: Int, response: HTTPURLResponse?, body: Data?) {
        guard let started = attemptStarted, let host = currentHost else { return }
        let elapsed = ClientTelemetry.clampedMilliseconds(now() - started)
        let verdict = response.flatMap(RetryPolicy.shouldRetryVerdict)
        let retryAfterMs: Int?
        if let seconds = response.flatMap(RetryPolicy.parseRetryAfter) {
            retryAfterMs = ClientTelemetry.boundedMilliseconds(seconds)
        } else {
            retryAfterMs = nil
        }
        let requestID = response.flatMap { RetryPolicy.header($0, "x-request-id") }
        let errorSource = body.flatMap(Self.errorSource)
        store(Attempt(
            index: currentIndex ?? attempts.count,
            host: host,
            outcome: statusCode < 400 ? "ok" : "http_error",
            httpStatus: statusCode,
            errorClass: nil,
            errorSource: errorSource,
            shouldRetry: verdict,
            retryAfterMs: retryAfterMs,
            elapsedMs: elapsed,
            ttfbMs: elapsed,
            requestID: ClientTelemetry.validRequestID(requestID),
            moved: false
        ), phase: "none")
    }

    /// Attach the closed error-source enum after a streaming diagnostic body
    /// has been drained. No body text is retained.
    func onErrorBody(_ body: Data) {
        guard !finished, !attempts.isEmpty, let source = Self.errorSource(body) else { return }
        attempts[attempts.count - 1].errorSource = source
    }

    private static func errorSource(_ body: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        let direct = root["source"] as? String
        let nested = (root["error"] as? [String: Any])?["source"] as? String
        let candidate = direct ?? nested
        return ["router", "provider", "unknown"].contains(candidate ?? "") ? candidate : nil
    }

    /// Record an attempt that threw before a usable response. Must be called
    /// with the ORIGINAL error at the engine's bare `catch` — after the SDK
    /// flattens it to a message string the class is unrecoverable (§6.1).
    func onTransportError(
        _ error: Error,
        responseOpened: Bool = false,
        bodyStarted: Bool = false
    ) {
        guard !finished else { return }
        guard let started = attemptStarted, let host = currentHost else { return }
        var errorClass = ClientTelemetry.classifyTransportError(
            error,
            responseOpened: responseOpened
        )
        let outcome: String
        var phase = "none"
        if ClientTelemetry.isTimeoutError(error) {
            outcome = "timeout"
            if bodyStarted {
                errorClass = "stream_stalled"
                phase = "idle"
            } else if responseOpened {
                phase = "first_byte"
            } else {
                phase = "connect"
            }
        } else if bodyStarted {
            outcome = "stream_broken"
        } else {
            outcome = "transport_error"
        }
        let index = currentIndex ?? attempts.count
        let previous = index < attempts.count ? attempts[index] : nil
        store(Attempt(
            index: index,
            host: host,
            outcome: outcome,
            httpStatus: responseOpened ? previous?.httpStatus : nil,
            errorClass: errorClass,
            errorSource: previous?.errorSource,
            shouldRetry: previous?.shouldRetry,
            retryAfterMs: previous?.retryAfterMs,
            elapsedMs: ClientTelemetry.clampedMilliseconds(now() - started),
            ttfbMs: responseOpened ? previous?.ttfbMs : nil,
            requestID: previous?.requestID,
            moved: false
        ), phase: phase)
    }

    /// Record that the candidate index advanced after the current attempt —
    /// the fact behind both `fo=1` and the previous attempt's `moved`.
    func onMoved() {
        guard !attempts.isEmpty else { return }
        attempts[attempts.count - 1].moved = true
        failoverUsed = true
    }

    /// Called by SSEParser exactly when it produces its first parsed event.
    func onFirstEvent() {
        guard !finished else { return }
        guard ttftMs == nil, let firstStarted else { return }
        ttftMs = ClientTelemetry.clampedMilliseconds(now() - firstStarted)
    }

    func onAborted() {
        guard !finished else { return }
        guard let started = attemptStarted, let host = currentHost else { return }
        let index = currentIndex ?? attempts.count
        let previous = index < attempts.count ? attempts[index] : nil
        store(Attempt(
            index: index,
            host: host,
            outcome: "aborted",
            httpStatus: previous?.httpStatus,
            errorClass: previous?.errorClass,
            errorSource: previous?.errorSource,
            shouldRetry: previous?.shouldRetry,
            retryAfterMs: previous?.retryAfterMs,
            elapsedMs: ClientTelemetry.clampedMilliseconds(now() - started),
            ttfbMs: previous?.ttfbMs,
            requestID: previous?.requestID,
            moved: previous?.moved ?? false
        ), phase: previous.flatMap { _ in index < attemptPhases.count ? attemptPhases[index] : nil } ?? "none")
    }

    private func configuredTimeoutMs(for phase: String) -> Int? {
        guard ["connect", "first_byte", "idle"].contains(phase),
              let configuredTimeout, configuredTimeout.isFinite, configuredTimeout > 0 else {
            return nil
        }
        return ClientTelemetry.boundedMilliseconds(configuredTimeout, minimum: 1)
    }

    /// Derive the one request event plus exact request/attempt counter rows.
    /// Idempotent and non-throwing; sampling is owned by TelemetryReporter.
    func finish(exhausted: Bool) {
        guard !finished else { return }
        finished = true
        guard ["GET", "POST"].contains(method), let reporter,
              !attempts.isEmpty, let firstStarted else { return }
        let final = attempts[attempts.count - 1]
        let finalOutcome = exhausted && attempts.count > 1 && final.outcome != "ok"
            ? "exhausted" : final.outcome
        let phase = attemptPhases.last ?? "none"
        let configuredMs = configuredTimeoutMs(for: phase)
        let totalMs = ClientTelemetry.clampedMilliseconds(now() - firstStarted)
        let wireAttempts = attempts.map {
            TelemetryAttemptRecord(
                index: $0.index, host: $0.host, outcome: $0.outcome,
                httpStatus: $0.httpStatus, errorClass: $0.errorClass,
                errorSource: $0.errorSource, shouldRetry: $0.shouldRetry,
                retryAfterMs: $0.retryAfterMs, elapsedMs: $0.elapsedMs,
                ttfbMs: $0.ttfbMs, requestID: $0.requestID, moved: $0.moved
            )
        }
        let event = TelemetryRequestEvent(
            endpoint: endpoint, method: method, streaming: streaming,
            providerPinned: providerPinned, model: model, attempts: wireAttempts,
            finalOutcome: finalOutcome, finalHTTPStatus: final.httpStatus,
            totalMs: totalMs, ttftMs: ttftMs, failoverUsed: failoverUsed,
            timeoutPhase: phase, configuredTimeoutMs: configuredMs,
            completedAt: now()
        )
        let counterOutcome = finalOutcome == "exhausted" ? final.outcome : finalOutcome
        let firstErrorClass = attempts.compactMap(\.errorClass).first
        let requestKey = TelemetryCounterKey(
            level: "request", endpoint: endpoint, streaming: streaming,
            host: final.host, outcome: counterOutcome, errorClass: firstErrorClass,
            httpStatusClass: ClientTelemetry.statusClass(final.httpStatus),
            timeoutPhase: phase,
            timeoutFloorMet: ClientTelemetry.timeoutFloorMet(phase, configuredMs: configuredMs),
            providerPinned: providerPinned
        )
        var requestIncrement = TelemetryCounterIncrement(
            requests: 1, attempts: attempts.count,
            failoverUsed: failoverUsed ? 1 : 0,
            firstAttemptSuccess: attempts.first?.outcome == "ok" ? 1 : 0,
            totalMsHistogram: [ClientTelemetry.latencyBucket(totalMs): 1]
        )
        if let firstEvent = ttftMs ?? final.ttfbMs {
            requestIncrement.firstEventMsHistogram = [ClientTelemetry.latencyBucket(firstEvent): 1]
        }
        var counters: [(TelemetryCounterKey, TelemetryCounterIncrement)] = [(requestKey, requestIncrement)]
        for (index, attempt) in attempts.enumerated() {
            let attemptPhase = index < attemptPhases.count ? attemptPhases[index] : "none"
            let attemptTimeout = configuredTimeoutMs(for: attemptPhase)
            let key = TelemetryCounterKey(
                level: "attempt", endpoint: endpoint, streaming: streaming,
                host: attempt.host, outcome: attempt.outcome, errorClass: attempt.errorClass,
                httpStatusClass: ClientTelemetry.statusClass(attempt.httpStatus),
                timeoutPhase: attemptPhase,
                timeoutFloorMet: ClientTelemetry.timeoutFloorMet(attemptPhase, configuredMs: attemptTimeout),
                providerPinned: providerPinned
            )
            counters.append((key, TelemetryCounterIncrement(
                requests: 1, attempts: 1, failoverUsed: attempt.moved ? 1 : 0,
                firstAttemptSuccess: 0
            )))
        }
        reporter.record(event: event, counters: counters)
    }

    func markExhausted(_ value: Bool) {
        exhaustedHint = exhaustedHint || value
    }

    func finish() {
        finish(exhausted: exhaustedHint)
    }

    private func store(_ attempt: Attempt, phase: String = "none") {
        if attempt.index < attempts.count {
            attempts[attempt.index] = attempt
            if attempt.index < attemptPhases.count { attemptPhases[attempt.index] = phase }
        } else {
            attempts.append(attempt)
            attemptPhases.append(ClientTelemetry.timeoutPhases.contains(phase) ? phase : "none")
        }
    }
}
