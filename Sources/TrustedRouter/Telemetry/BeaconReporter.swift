import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Client telemetry contract v1, beacon channel (sections 4, 5, 6.2-6.4).
// The reporter deliberately owns a URLSession and performs one data(for:)
// call per flush. It never calls rawRequest or withTransportRetries.

extension ClientTelemetry {
    static let telemetryFlushSeconds = 30.0
    static let telemetryMaxEvents = 1_000
    static let telemetryMaxBatchEvents = 100
    static let telemetryMaxBatchCounters = 200
    static let telemetryMaxWindowKeys = 256
    static let telemetryRetentionSeconds = 86_400.0
    static let telemetryRetentionBytes = 512 * 1_024
    static let telemetryMaxBatchBytes = 65_536
    static let telemetryBatchTriggerBytes = 60 * 1_024
    static let telemetryBackoffMinSeconds = 60.0
    static let telemetryBackoffMaxSeconds = 600.0

    static let timeoutPhases: Set<String> = ["none", "connect", "first_byte", "idle", "total"]
    static let latencyBuckets = [
        "lt100", "lt200", "lt400", "lt800", "lt1600", "lt3200",
        "lt6400", "lt12800", "lt25600", "lt51200", "lt102400", "ge102400"
    ]

    static func endpointEnum(_ path: String) -> String {
        let clean = (URLComponents(string: path)?.path ?? path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value = "/" + clean
        switch value {
        case "/chat/completions": return "chat_completions"
        case "/messages": return "messages"
        case "/responses": return "responses"
        case "/embeddings": return "embeddings"
        default:
            for (prefix, endpoint) in [
                ("/images", "images"), ("/videos", "videos"),
                ("/models", "models"), ("/fusion", "fusion")
            ] where value == prefix || value.hasPrefix(prefix + "/") {
                return endpoint
            }
            return "inference_other"
        }
    }

    static func latencyBucket(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        for (upper, bucket) in zip(
            [100, 200, 400, 800, 1_600, 3_200, 6_400, 12_800, 25_600, 51_200, 102_400],
            latencyBuckets.dropLast()
        ) where value < upper {
            return bucket
        }
        return "ge102400"
    }

    static func statusClass(_ status: Int?) -> String {
        guard let status else { return "none" }
        if (200...299).contains(status) { return "2xx" }
        if status == 429 { return "429" }
        if (400...499).contains(status) { return "4xx" }
        if (500...599).contains(status) { return "5xx" }
        return "none"
    }

    static func timeoutFloorMet(_ phase: String, configuredMs: Int?) -> Bool {
        guard let configuredMs else { return false }
        switch phase {
        case "connect": return configuredMs >= 10_000
        case "first_byte": return configuredMs >= 60_000
        case "idle": return configuredMs >= 30_000
        default: return false
        }
    }

    static func boundedInt(_ value: Int, minimum: Int, maximum: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    static func boundedMilliseconds(_ seconds: Double, minimum: Int = 0) -> Int? {
        guard seconds.isFinite, seconds > 0 else { return minimum == 0 ? 0 : nil }
        let milliseconds = seconds * 1_000.0
        guard milliseconds.isFinite else { return maxDurationMs }
        if milliseconds >= Double(maxDurationMs) { return maxDurationMs }
        if milliseconds < Double(minimum) { return minimum == 0 ? 0 : nil }
        return Int(milliseconds)
    }

    static func saturatedAdd(_ left: Int, _ right: Int) -> Int {
        guard right > 0 else { return left }
        return left > Int.max - right ? Int.max : left + right
    }

    static func validModel(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/~@-")
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    static func validRequestID(_ value: String?) -> String? {
        guard let value, value.count == 37, value.hasPrefix("rlog_") else { return nil }
        return value.dropFirst(5).allSatisfy { $0.isHexDigit && !$0.isUppercase } ? value : nil
    }
}

struct TelemetryAttemptRecord: Sendable {
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

    func wire() -> [String: Any] {
        let boundedErrorSource: Any
        if let errorSource, ["router", "provider", "unknown"].contains(errorSource) {
            boundedErrorSource = errorSource
        } else {
            boundedErrorSource = NSNull()
        }
        var result: [String: Any] = [
            "index": ClientTelemetry.boundedInt(index, minimum: 0, maximum: 99),
            "host": ClientTelemetry.hosts.contains(host) ? host : "custom",
            "outcome": ClientTelemetry.outcomes.contains(outcome) ? outcome : "transport_error",
            "http_status": httpStatus.map { ClientTelemetry.boundedInt($0, minimum: 100, maximum: 599) } ?? NSNull(),
            "error_class": errorClass.flatMap { ClientTelemetry.errorClasses.contains($0) ? $0 : nil } ?? NSNull(),
            "error_source": boundedErrorSource,
            "retry_after_ms": retryAfterMs.map { ClientTelemetry.boundedInt($0, minimum: 0, maximum: ClientTelemetry.maxDurationMs) } ?? NSNull(),
            "elapsed_ms": ClientTelemetry.boundedInt(elapsedMs, minimum: 0, maximum: ClientTelemetry.maxDurationMs),
            "ttfb_ms": ttfbMs.map { ClientTelemetry.boundedInt($0, minimum: 0, maximum: ClientTelemetry.maxDurationMs) } ?? NSNull(),
            "request_id": ClientTelemetry.validRequestID(requestID) ?? NSNull(),
            "moved": moved
        ]
        if let shouldRetry { result["should_retry"] = shouldRetry }
        return result
    }
}

struct TelemetryRequestEvent: Sendable {
    var endpoint: String
    var method: String
    var streaming: Bool
    var providerPinned: Bool
    var model: String?
    var attempts: [TelemetryAttemptRecord]
    var finalOutcome: String
    var finalHTTPStatus: Int?
    var totalMs: Int
    var ttftMs: Int?
    var failoverUsed: Bool
    var timeoutPhase: String
    var configuredTimeoutMs: Int?
    var completedAt: Double
    var sampleRate: Double = 1
    var sampleReason: String = "failure"

    func wire(now: Double) -> [String: Any]? {
        let attemptValues = attempts.prefix(16).map { $0.wire() }
        guard !attemptValues.isEmpty, ["GET", "POST"].contains(method) else { return nil }
        let rawAge = (now - completedAt) * 1_000.0
        let age: Int
        if !rawAge.isFinite || rawAge <= 0 { age = 0 }
        else if rawAge >= 86_400_000 { age = 86_400_000 }
        else { age = Int(rawAge) }
        let rate = sampleRate.isFinite ? min(1, max(0, sampleRate)) : 0
        guard rate > 0, ["failure", "retried", "slow", "random"].contains(sampleReason) else {
            return nil
        }
        let fallbackOutcome = attempts.last?.outcome ?? "transport_error"
        return [
            "age_ms": age,
            "plane": "inference",
            "endpoint": ClientTelemetry.endpoints.contains(endpoint) ? endpoint : "inference_other",
            "method": method,
            "streaming": streaming,
            "provider_pinned": providerPinned,
            "model": ClientTelemetry.validModel(model) ?? NSNull(),
            "attempts": attemptValues,
            "final_outcome": ClientTelemetry.finalOutcomes.contains(finalOutcome) ? finalOutcome : fallbackOutcome,
            "final_http_status": finalHTTPStatus.map { ClientTelemetry.boundedInt($0, minimum: 100, maximum: 599) } ?? NSNull(),
            "total_ms": ClientTelemetry.boundedInt(totalMs, minimum: 0, maximum: ClientTelemetry.maxDurationMs),
            "ttft_ms": ttftMs.map { ClientTelemetry.boundedInt($0, minimum: 0, maximum: ClientTelemetry.maxDurationMs) } ?? NSNull(),
            "failover_used": failoverUsed,
            "timeout_phase": ClientTelemetry.timeoutPhases.contains(timeoutPhase) ? timeoutPhase : "none",
            "configured_timeout_ms": configuredTimeoutMs.map { ClientTelemetry.boundedInt($0, minimum: 1, maximum: ClientTelemetry.maxDurationMs) } ?? NSNull(),
            "sample_rate": rate,
            "sample_reason": sampleReason
        ]
    }
}

struct TelemetryCounterKey: Hashable, Sendable {
    var level: String
    var endpoint: String
    var streaming: Bool
    var host: String
    var outcome: String
    var errorClass: String?
    var httpStatusClass: String
    var timeoutPhase: String
    var timeoutFloorMet: Bool
    var providerPinned: Bool
}

struct TelemetryCounterIncrement: Sendable {
    var requests = 0
    var attempts = 0
    var failoverUsed = 0
    var firstAttemptSuccess = 0
    var totalMsHistogram: [String: Int] = [:]
    var firstEventMsHistogram: [String: Int] = [:]

    mutating func merge(_ other: TelemetryCounterIncrement) {
        requests = ClientTelemetry.saturatedAdd(requests, max(0, other.requests))
        attempts = ClientTelemetry.saturatedAdd(attempts, max(0, other.attempts))
        failoverUsed = ClientTelemetry.saturatedAdd(failoverUsed, max(0, other.failoverUsed))
        firstAttemptSuccess = ClientTelemetry.saturatedAdd(firstAttemptSuccess, max(0, other.firstAttemptSuccess))
        mergeHistogram(&totalMsHistogram, other.totalMsHistogram)
        mergeHistogram(&firstEventMsHistogram, other.firstEventMsHistogram)
    }

    private func mergeHistogram(_ target: inout [String: Int], _ source: [String: Int]) {
        for (bucket, count) in source where ClientTelemetry.latencyBuckets.contains(bucket) {
            target[bucket] = ClientTelemetry.saturatedAdd(target[bucket] ?? 0, max(0, count))
        }
    }
}

private final class TelemetryEventBox: @unchecked Sendable {
    let event: TelemetryRequestEvent
    let estimatedBytes: Int
    init(event: TelemetryRequestEvent, estimatedBytes: Int) {
        self.event = event
        self.estimatedBytes = estimatedBytes
    }
}

private final class TelemetryCounterWindow: @unchecked Sendable {
    let start: Double
    var rows: [TelemetryCounterKey: TelemetryCounterIncrement]
    var sizeBytes: Int
    init(start: Double, rows: [TelemetryCounterKey: TelemetryCounterIncrement], sizeBytes: Int = 0) {
        self.start = start
        self.rows = rows
        self.sizeBytes = sizeBytes
    }
}

private struct TelemetryBatchSelection {
    let body: [String: Any]
    let data: Data
    let events: [TelemetryEventBox]
    let counters: [(TelemetryCounterWindow, TelemetryCounterKey)]
    let dropped: Int
}

private actor TelemetryFlushGate {
    func flush(_ reporter: TelemetryReporter, force: Bool, timeout: Double?) async -> Bool {
        await reporter.performFlush(force: force, timeout: timeout)
    }
}

/// A single-consumer, coalescing wake-up primitive. Waiting is implemented by
/// a sleeping Swift task and a checked continuation, so it never parks a
/// cooperative-pool thread.
private final class TelemetryWorkerWake: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
        var timeout: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var waiter: Waiter?
    private var nextID: UInt64 = 0
    private var pending = false
    private var finished = false

    func wait(seconds: Double) async {
        let nanoseconds = Self.nanoseconds(seconds)
        guard nanoseconds > 0 else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(continuation, nanoseconds: nanoseconds)
            }
        } onCancel: {
            signal()
        }
    }

    func signal() {
        let released = lock.withLock { () -> Waiter? in
            guard !finished else { return nil }
            guard let waiter else {
                pending = true
                return nil
            }
            self.waiter = nil
            return waiter
        }
        released?.timeout?.cancel()
        released?.continuation.resume()
    }

    func finish() {
        let released = lock.withLock { () -> Waiter? in
            guard !finished else { return nil }
            finished = true
            pending = false
            defer { waiter = nil }
            return waiter
        }
        released?.timeout?.cancel()
        released?.continuation.resume()
    }

    private func register(
        _ continuation: CheckedContinuation<Void, Never>,
        nanoseconds: UInt64
    ) {
        var id: UInt64?
        let resumeImmediately = lock.withLock { () -> Bool in
            if finished || pending {
                pending = false
                return true
            }
            let candidate = nextID
            nextID = nextID == UInt64.max ? 0 : nextID + 1
            waiter = Waiter(id: candidate, continuation: continuation, timeout: nil)
            id = candidate
            return false
        }
        guard !resumeImmediately, let id else {
            continuation.resume()
            return
        }

        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.timeoutFired(id: id)
        }
        let installed = lock.withLock { () -> Bool in
            guard waiter?.id == id else { return false }
            waiter?.timeout = timeout
            return true
        }
        if !installed { timeout.cancel() }
    }

    private func timeoutFired(id: UInt64) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard waiter?.id == id else { return nil }
            defer { waiter = nil }
            return waiter?.continuation
        }
        continuation?.resume()
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let bounded = min(ClientTelemetry.telemetryBackoffMaxSeconds, seconds)
        return UInt64(bounded * 1_000_000_000)
    }
}

final class TelemetryReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let wake = TelemetryWorkerWake()
    private let flushGate = TelemetryFlushGate()
    private let controlBaseURL: String
    private let apiKey: String?
    private let workspaceID: String?
    private let session: URLSession
    private let clock: @Sendable () -> Double
    private let wallClock: @Sendable () -> Double
    private let random: @Sendable () -> Double
    private let debug: Bool
    private let instanceID: String

    private var successSampleRate: Double
    private var flushSeconds: Double
    private var events: [TelemetryEventBox] = []
    private var eventsSizeBytes = 0
    private var currentWindowStart: Double?
    private var currentCounters: [TelemetryCounterKey: TelemetryCounterIncrement] = [:]
    private var closedWindows: [TelemetryCounterWindow] = []
    private var retainedWindowBytes = 0
    private var droppedSinceLast = 0
    private var sequence = 0
    private var backoffSeconds = ClientTelemetry.telemetryBackoffMinSeconds
    private var backoffUntil = 0.0
    private var pausedUntil = 0.0
    private var nextFlushAt = 0.0
    private var urgentFlush = false
    private var disabled = false
    private var closed = false
    private var worker: Task<Void, Never>?

    init(
        controlBaseURL: String,
        apiKey: String?,
        workspaceID: String?,
        successSampleRate: Double = 0.01,
        flushSeconds: Double = ClientTelemetry.telemetryFlushSeconds,
        session: URLSession? = nil,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        debug: Bool? = nil
    ) {
        self.controlBaseURL = controlBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.workspaceID = workspaceID
        self.successSampleRate = Self.sampleRate(successSampleRate)
        self.flushSeconds = Self.flushInterval(flushSeconds)
        self.clock = clock
        self.wallClock = wallClock
        self.random = random
        self.debug = debug
            ?? (ProcessInfo.processInfo.environment["TRUSTEDROUTER_TELEMETRY_DEBUG"] == "1")
        self.instanceID = String(Self.hexID().prefix(16))
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            configuration.httpAdditionalHeaders = nil
            self.session = URLSession(configuration: configuration)
        }
        TelemetryReporterRegistry.shared.register(self)
    }

    private static func sampleRate(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.01
    }

    private static func flushInterval(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return ClientTelemetry.telemetryFlushSeconds }
        return min(ClientTelemetry.telemetryBackoffMaxSeconds, value)
    }

    private static func hexID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func safeNow() -> Double {
        let value = clock()
        return value.isFinite ? max(0, value) : 0
    }

    func monotonicNow() -> Double { safeNow() }

    func record(event source: TelemetryRequestEvent, counters: [(TelemetryCounterKey, TelemetryCounterIncrement)]) {
        let now = safeNow()
        var sampled: TelemetryRequestEvent?
        if source.finalOutcome != "ok" {
            sampled = source
            sampled?.sampleReason = "failure"
            sampled?.sampleRate = 1
        } else if source.attempts.count > 1 || source.failoverUsed {
            sampled = source
            sampled?.sampleReason = "retried"
            sampled?.sampleRate = 1
        } else if source.totalMs > 30_000 {
            sampled = source
            sampled?.sampleReason = "slow"
            sampled?.sampleRate = 1
        } else {
            let rate = lock.withLock { successSampleRate }
            let draw = random()
            if rate > 0, draw.isFinite, draw >= 0, draw < rate {
                sampled = source
                sampled?.sampleReason = "random"
                sampled?.sampleRate = rate
            }
        }

        lock.lock()
        defer { lock.unlock() }
        guard !disabled, !closed else { return }
        rollWindow(now)
        mergeCounters(counters)
        if let sampled, let wire = sampled.wire(now: now),
           let estimate = try? JSONSerialization.data(withJSONObject: wire).count {
            appendEvent(sampled, estimatedBytes: estimate)
        }
        startWorker(now)
        if events.count >= 50
            || eventsSizeBytes + retainedWindowBytes + currentCounters.count * 400
                >= ClientTelemetry.telemetryBatchTriggerBytes {
            urgentFlush = true
            wake.signal()
        }
    }

    private func startWorker(_ now: Double) {
        guard worker == nil, !disabled, !closed else { return }
        nextFlushAt = now + flushSeconds
        let wake = wake
        worker = Task.detached(priority: .utility) { [self, wake] in
            while true {
                let state = workerState()
                if state.0 { return }
                if state.1 > 0 {
                    await wake.wait(seconds: state.1)
                    continue
                }
                _ = await flushNow()
                lock.withLock {
                    nextFlushAt = safeNow() + flushSeconds
                }
            }
        }
    }

    private func workerState() -> (Bool, Double) {
        lock.withLock {
            if disabled || closed { return (true, 0) }
            let now = safeNow()
            let blockedUntil = max(pausedUntil, backoffUntil)
            if urgentFlush && now >= blockedUntil {
                urgentFlush = false
                return (false, 0)
            }
            return (
                false,
                min(
                    ClientTelemetry.telemetryBackoffMaxSeconds,
                    max(0, max(nextFlushAt, blockedUntil) - now)
                )
            )
        }
    }

    deinit {
        worker?.cancel()
        wake.finish()
        session.invalidateAndCancel()
    }

    @discardableResult
    func flushNow() async -> Bool {
        await flushGate.flush(self, force: false, timeout: nil)
    }

    fileprivate func performFlush(force: Bool, timeout: Double?) async -> Bool {
        let now = safeNow()
        let allowed = lock.withLock {
            !disabled && (force || !closed) && (force || now >= max(pausedUntil, backoffUntil))
        }
        guard allowed, let apiKey, !apiKey.isEmpty else { return false }
        guard let selection = lock.withLock({ selectBatch(now: now) }) else { return false }

        if debug {
            let prefix = Data("trustedrouter telemetry batch: ".utf8)
            FileHandle.standardError.write(prefix + selection.data + Data([10]))
        }

        guard let url = URL(string: controlBaseURL + ClientTelemetry.beaconPath) else {
            lock.withLock { setBackoff(safeNow(), retryAfter: nil) }
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = selection.data
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(TrustedRouter.userAgent, forHTTPHeaderField: "user-agent")
        if let workspaceID, !workspaceID.isEmpty {
            request.setValue(workspaceID, forHTTPHeaderField: "x-trustedrouter-workspace")
        }
        if let timeout {
            request.timeoutInterval = timeout.isFinite ? max(0.001, min(5, timeout)) : 0.001
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lock.withLock { setBackoff(safeNow(), retryAfter: nil) }
                return false
            }
            handleResponse(http, data: data, selection: selection, now: safeNow())
            return http.statusCode == 202
        } catch {
            lock.withLock { setBackoff(safeNow(), retryAfter: nil) }
            return false
        }
    }

    private func handleResponse(
        _ response: HTTPURLResponse,
        data: Data,
        selection: TelemetryBatchSelection,
        now: Double
    ) {
        lock.withLock {
            if RetryPolicy.header(response, "x-tr-telemetry")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" {
                disable()
                return
            }
            switch response.statusCode {
            case 202:
                remove(selection)
                droppedSinceLast = max(0, droppedSinceLast - selection.dropped)
                backoffSeconds = ClientTelemetry.telemetryBackoffMinSeconds
                backoffUntil = 0
                applyPolicy(data, now: now)
            case 400, 401, 403, 404, 410:
                disable()
            case 413:
                remove(selection)
                droppedSinceLast = ClientTelemetry.saturatedAdd(
                    droppedSinceLast, selection.events.count + selection.counters.count
                )
            default:
                setBackoff(now, retryAfter: retryAfter(response))
            }
        }
    }

    private func retryAfter(_ response: HTTPURLResponse) -> Double? {
        guard let raw = RetryPolicy.header(response, "retry-after"),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 0, value <= 600 else { return nil }
        return value
    }

    private func setBackoff(_ now: Double, retryAfter: Double?) {
        let delay = min(
            ClientTelemetry.telemetryBackoffMaxSeconds,
            max(backoffSeconds, retryAfter ?? 0)
        )
        backoffUntil = now + delay
        backoffSeconds = min(
            ClientTelemetry.telemetryBackoffMaxSeconds,
            max(ClientTelemetry.telemetryBackoffMinSeconds, backoffSeconds * 2)
        )
        wake.signal()
    }

    private func applyPolicy(_ data: Data, now: Double) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policy = root["policy"] as? [String: Any] else { return }
        if let value = finiteDouble(policy["success_sample_rate"]),
           value >= 0, value < successSampleRate {
            successSampleRate = value
        }
        if let value = finiteDouble(policy["flush_seconds"]), value > flushSeconds {
            flushSeconds = min(ClientTelemetry.telemetryBackoffMaxSeconds, value)
        }
        if let value = finiteDouble(policy["pause_seconds"]), value >= 0, value <= 86_400 {
            pausedUntil = max(pausedUntil, now + value)
        }
    }

    private func finiteDouble(_ value: Any?) -> Double? {
        let parsed: Double?
        if let number = value as? NSNumber { parsed = number.doubleValue }
        else if let string = value as? String { parsed = Double(string) }
        else { parsed = nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private func minuteStart(_ now: Double) -> Double {
        floor(max(0, now) / 60) * 60
    }

    private func rollWindow(_ now: Double) {
        let minute = minuteStart(now)
        guard let start = currentWindowStart else {
            currentWindowStart = minute
            return
        }
        if minute > start {
            closeCurrentWindow(now)
            currentWindowStart = minute
        }
    }

    private func foldedKey(_ key: TelemetryCounterKey, endpoint: Bool) -> TelemetryCounterKey {
        var result = key
        result.errorClass = "unknown"
        if endpoint { result.endpoint = "inference_other" }
        return result
    }

    private func errorCompatible(_ left: TelemetryCounterKey, _ right: TelemetryCounterKey) -> Bool {
        left.level == right.level && left.endpoint == right.endpoint
            && left.streaming == right.streaming && left.host == right.host
            && left.outcome == right.outcome && left.httpStatusClass == right.httpStatusClass
            && left.timeoutPhase == right.timeoutPhase && left.timeoutFloorMet == right.timeoutFloorMet
            && left.providerPinned == right.providerPinned
    }

    private func endpointCompatible(_ left: TelemetryCounterKey, _ right: TelemetryCounterKey) -> Bool {
        left.level == right.level && left.streaming == right.streaming && left.host == right.host
            && left.outcome == right.outcome && left.httpStatusClass == right.httpStatusClass
            && left.timeoutPhase == right.timeoutPhase && left.timeoutFloorMet == right.timeoutFloorMet
            && left.providerPinned == right.providerPinned
    }

    private func counterTarget(_ key: TelemetryCounterKey) -> TelemetryCounterKey {
        if currentCounters[key] != nil || currentCounters.count < ClientTelemetry.telemetryMaxWindowKeys {
            return key
        }
        let errorFolded = foldedKey(key, endpoint: false)
        if currentCounters[errorFolded] != nil { return errorFolded }
        if let compatible = currentCounters.keys.first(where: { errorCompatible($0, key) }),
           let previous = currentCounters.removeValue(forKey: compatible) {
            let target = foldedKey(compatible, endpoint: false)
            var merged = currentCounters[target] ?? TelemetryCounterIncrement()
            merged.merge(previous)
            currentCounters[target] = merged
            return target
        }
        let endpointFolded = foldedKey(key, endpoint: true)
        if currentCounters[endpointFolded] != nil { return endpointFolded }
        if let compatible = currentCounters.keys.first(where: { endpointCompatible($0, key) }),
           let previous = currentCounters.removeValue(forKey: compatible) {
            let target = foldedKey(compatible, endpoint: true)
            var merged = currentCounters[target] ?? TelemetryCounterIncrement()
            merged.merge(previous)
            currentCounters[target] = merged
            return target
        }
        return currentCounters.keys.first ?? key
    }

    private func normalise(_ key: TelemetryCounterKey) -> TelemetryCounterKey? {
        guard ["attempt", "request"].contains(key.level),
              ClientTelemetry.finalOutcomes.contains(key.outcome) else { return nil }
        var result = key
        if !ClientTelemetry.endpoints.contains(result.endpoint) { result.endpoint = "inference_other" }
        if !ClientTelemetry.hosts.contains(result.host) { result.host = "custom" }
        if let value = result.errorClass, !ClientTelemetry.errorClasses.contains(value) {
            result.errorClass = "unknown"
        }
        if !["none", "2xx", "4xx", "429", "5xx"].contains(result.httpStatusClass) {
            result.httpStatusClass = "none"
        }
        if !ClientTelemetry.timeoutPhases.contains(result.timeoutPhase) { result.timeoutPhase = "none" }
        return result
    }

    private func mergeCounters(_ counters: [(TelemetryCounterKey, TelemetryCounterIncrement)]) {
        for (rawKey, increment) in counters {
            guard let key = normalise(rawKey) else {
                droppedSinceLast = ClientTelemetry.saturatedAdd(droppedSinceLast, 1)
                continue
            }
            let target = counterTarget(key)
            var row = currentCounters[target] ?? TelemetryCounterIncrement()
            row.merge(increment)
            currentCounters[target] = row
        }
    }

    private func appendEvent(_ event: TelemetryRequestEvent, estimatedBytes: Int) {
        if events.count >= ClientTelemetry.telemetryMaxEvents {
            let index = events.firstIndex(where: { $0.event.finalOutcome == "ok" }) ?? 0
            let removed = events.remove(at: index)
            eventsSizeBytes = max(0, eventsSizeBytes - removed.estimatedBytes)
            droppedSinceLast = ClientTelemetry.saturatedAdd(droppedSinceLast, 1)
        }
        events.append(TelemetryEventBox(event: event, estimatedBytes: estimatedBytes))
        eventsSizeBytes = ClientTelemetry.saturatedAdd(eventsSizeBytes, estimatedBytes)
    }

    private func counterWire(
        _ key: TelemetryCounterKey,
        _ value: TelemetryCounterIncrement,
        ageMs: Int
    ) -> [String: Any] {
        let boundedHistogram: ([String: Int]) -> [String: Int] = { histogram in
            var result: [String: Int] = [:]
            for (bucket, count) in histogram where ClientTelemetry.latencyBuckets.contains(bucket) {
                result[bucket] = ClientTelemetry.boundedInt(count, minimum: 0, maximum: 10_000_000)
            }
            return result
        }
        return [
            "window_start_age_ms": ClientTelemetry.boundedInt(ageMs, minimum: 0, maximum: 86_400_000),
            "level": key.level, "endpoint": key.endpoint, "streaming": key.streaming,
            "host": key.host, "outcome": key.outcome,
            "error_class": key.errorClass ?? NSNull(),
            "http_status_class": key.httpStatusClass, "timeout_phase": key.timeoutPhase,
            "timeout_floor_met": key.timeoutFloorMet, "provider_pinned": key.providerPinned,
            "requests": ClientTelemetry.boundedInt(value.requests, minimum: 1, maximum: 10_000_000),
            "attempts": ClientTelemetry.boundedInt(value.attempts, minimum: 0, maximum: 10_000_000),
            "failover_used": ClientTelemetry.boundedInt(value.failoverUsed, minimum: 0, maximum: 10_000_000),
            "first_attempt_success": ClientTelemetry.boundedInt(value.firstAttemptSuccess, minimum: 0, maximum: 10_000_000),
            "total_ms_hist": boundedHistogram(value.totalMsHistogram),
            "first_event_ms_hist": boundedHistogram(value.firstEventMsHistogram)
        ]
    }

    private func windowSize(_ window: TelemetryCounterWindow) -> Int {
        let rows = window.rows.map { counterWire($0.key, $0.value, ageMs: 0) }
        return (try? JSONSerialization.data(withJSONObject: rows).count) ?? 0
    }

    private func closeCurrentWindow(_ now: Double) {
        guard !currentCounters.isEmpty, let start = currentWindowStart else { return }
        let window = TelemetryCounterWindow(start: start, rows: currentCounters)
        window.sizeBytes = windowSize(window)
        closedWindows.append(window)
        retainedWindowBytes = ClientTelemetry.saturatedAdd(retainedWindowBytes, window.sizeBytes)
        currentCounters = [:]
        currentWindowStart = minuteStart(now)
        pruneWindows(now)
    }

    private func pruneWindows(_ now: Double) {
        while let first = closedWindows.first,
              now - first.start > ClientTelemetry.telemetryRetentionSeconds {
            dropWindow(closedWindows.removeFirst())
        }
        while retainedWindowBytes > ClientTelemetry.telemetryRetentionBytes,
              !closedWindows.isEmpty {
            dropWindow(closedWindows.removeFirst())
        }
    }

    private func dropWindow(_ window: TelemetryCounterWindow) {
        retainedWindowBytes = max(0, retainedWindowBytes - window.sizeBytes)
        droppedSinceLast = ClientTelemetry.saturatedAdd(droppedSinceLast, window.rows.count)
    }

    private func selectBatch(now: Double) -> TelemetryBatchSelection? {
        rollWindow(now)
        closeCurrentWindow(now)
        pruneWindows(now)

        var eventRefs: [TelemetryEventBox] = []
        var wireEvents: [[String: Any]] = []
        for box in events.prefix(ClientTelemetry.telemetryMaxBatchEvents) {
            if let wire = box.event.wire(now: now) {
                eventRefs.append(box)
                wireEvents.append(wire)
            } else {
                droppedSinceLast = ClientTelemetry.saturatedAdd(droppedSinceLast, 1)
            }
        }
        var counterRefs: [(TelemetryCounterWindow, TelemetryCounterKey)] = []
        var wireCounters: [[String: Any]] = []
        outer: for window in closedWindows {
            let rawAge = (now - window.start) * 1_000.0
            let age = !rawAge.isFinite || rawAge <= 0 ? 0
                : rawAge >= 86_400_000 ? 86_400_000 : Int(rawAge)
            for (key, increment) in window.rows {
                counterRefs.append((window, key))
                wireCounters.append(counterWire(key, increment, ageMs: age))
                if wireCounters.count >= ClientTelemetry.telemetryMaxBatchCounters { break outer }
            }
        }
        guard !wireEvents.isEmpty || !wireCounters.isEmpty else { return nil }

        let dropped = droppedSinceLast
        let wall = wallClock() * 1_000.0
        let sentAt: Int
        if !wall.isFinite || wall <= 0 { sentAt = 0 }
        else if wall >= Double(Int.max) { sentAt = Int.max }
        else { sentAt = Int(wall) }
        var body: [String: Any] = [
            "schema_version": ClientTelemetry.schemaVersion,
            "batch_id": Self.hexID(),
            "instance_id": instanceID,
            "seq": max(0, sequence),
            "sent_at_ms": sentAt,
            "sdk": Self.sdkIdentity(),
            "synthetic": false,
            "dropped_since_last": max(0, dropped),
            "events": wireEvents,
            "counters": wireCounters
        ]
        if sequence < Int.max { sequence += 1 }

        while let data = try? JSONSerialization.data(withJSONObject: body),
              data.count > ClientTelemetry.telemetryMaxBatchBytes {
            if !wireEvents.isEmpty {
                wireEvents.removeLast()
                eventRefs.removeLast()
            } else if !wireCounters.isEmpty {
                wireCounters.removeLast()
                counterRefs.removeLast()
            } else { return nil }
            body["events"] = wireEvents
            body["counters"] = wireCounters
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              data.count <= ClientTelemetry.telemetryMaxBatchBytes,
              !eventRefs.isEmpty || !counterRefs.isEmpty else { return nil }
        return TelemetryBatchSelection(
            body: body, data: data, events: eventRefs, counters: counterRefs, dropped: dropped
        )
    }

    private static func sdkIdentity() -> [String: String] {
        #if os(macOS)
        let os = "macos"
        #elseif os(iOS)
        let os = "ios"
        #elseif os(Linux)
        let os = "linux"
        #elseif os(Windows)
        let os = "windows"
        #elseif os(Android)
        let os = "android"
        #elseif os(FreeBSD)
        let os = "freebsd"
        #else
        let os = "other"
        #endif
        #if arch(x86_64)
        let arch = "x64"
        #elseif arch(i386)
        let arch = "x32"
        #elseif arch(arm64)
        let arch = "arm64"
        #elseif arch(arm)
        let arch = "arm"
        #elseif arch(wasm32)
        let arch = "wasm"
        #else
        let arch = "other"
        #endif
        let version = TrustedRouterConstants.version.utf8.count <= 32
            ? TrustedRouterConstants.version : "0.0.0"
        return [
            "name": "tr-swift", "version": version, "lang": "swift",
            "runtime": "swift/5.9.0", "os": os, "arch": arch
        ]
    }

    private func remove(_ selection: TelemetryBatchSelection) {
        let selectedEvents = Set(selection.events.map(ObjectIdentifier.init))
        events.removeAll { selectedEvents.contains(ObjectIdentifier($0)) }
        eventsSizeBytes = events.reduce(0) {
            ClientTelemetry.saturatedAdd($0, $1.estimatedBytes)
        }
        var changed = Set<ObjectIdentifier>()
        for (window, key) in selection.counters where window.rows.removeValue(forKey: key) != nil {
            changed.insert(ObjectIdentifier(window))
        }
        for window in closedWindows where changed.contains(ObjectIdentifier(window)) {
            retainedWindowBytes = max(0, retainedWindowBytes - window.sizeBytes)
            window.sizeBytes = window.rows.isEmpty ? 0 : windowSize(window)
            retainedWindowBytes = ClientTelemetry.saturatedAdd(retainedWindowBytes, window.sizeBytes)
        }
        closedWindows.removeAll { $0.rows.isEmpty }
    }

    private func disable() {
        disabled = true
        events = []
        eventsSizeBytes = 0
        currentCounters = [:]
        closedWindows = []
        retainedWindowBytes = 0
        droppedSinceLast = 0
        worker?.cancel()
        wake.finish()
    }

    /// Synchronously waits for the bounded final flush. Async callers running
    /// on a cooperative executor should use `shutdown(timeout:)` instead.
    func close(timeout: Double = 2.0) {
        let bounded = timeout.isFinite ? min(2, max(0, timeout)) : 0
        let shouldClose = lock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            worker?.cancel()
            wake.finish()
            return true
        }
        guard shouldClose else { return }
        guard bounded > 0 else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) { [self] in
            _ = await flushGate.flush(self, force: true, timeout: bounded)
            done.signal()
        }
        _ = done.wait(timeout: .now() + bounded)
    }

    func shutdown(timeout: Double = 2.0) async {
        let bounded = timeout.isFinite ? min(2, max(0, timeout)) : 0
        let shouldClose = lock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            worker?.cancel()
            wake.finish()
            return true
        }
        guard shouldClose, bounded > 0 else { return }
        let done = TelemetryWorkerWake()
        let finalFlush = Task.detached(priority: .utility) { [self, done] in
            _ = await flushGate.flush(self, force: true, timeout: bounded)
            done.finish()
        }
        await done.wait(seconds: bounded)
        finalFlush.cancel()
    }

    // Internal observations used by deterministic contract tests.
    var workerStarted: Bool { lock.withLock { worker != nil } }
    var isDisabled: Bool { lock.withLock { disabled } }
    var bufferedEventCount: Int { lock.withLock { events.count } }
    var droppedCount: Int { lock.withLock { droppedSinceLast } }
    var currentCounterSnapshot: [TelemetryCounterKey: TelemetryCounterIncrement] {
        lock.withLock { currentCounters }
    }
    var policySnapshot: (Double, Double, Double) {
        lock.withLock { (successSampleRate, flushSeconds, pausedUntil) }
    }
}

private final class WeakTelemetryReporter: @unchecked Sendable {
    weak var value: TelemetryReporter?
    init(_ value: TelemetryReporter) { self.value = value }
}

private final class TelemetryReporterRegistry: @unchecked Sendable {
    static let shared = TelemetryReporterRegistry()
    private let lock = NSLock()
    private var reporters: [WeakTelemetryReporter] = []

    private init() {
        atexit {
            TelemetryReporterRegistry.shared.closeAll()
        }
    }

    func register(_ reporter: TelemetryReporter) {
        lock.withLock {
            reporters.removeAll { $0.value == nil }
            reporters.append(WeakTelemetryReporter(reporter))
        }
    }

    private func closeAll() {
        let values = lock.withLock { reporters.compactMap(\.value) }
        for reporter in values { reporter.close(timeout: 2) }
    }
}

final class TelemetryReporterStore: @unchecked Sendable {
    private let lock = NSLock()
    private let makeReporter: @Sendable () -> TelemetryReporter
    private var value: TelemetryReporter?

    init(makeReporter: @escaping @Sendable () -> TelemetryReporter) {
        self.makeReporter = makeReporter
    }

    func reporter() -> TelemetryReporter {
        lock.withLock {
            if let value { return value }
            let created = makeReporter()
            value = created
            return created
        }
    }

    func existing() -> TelemetryReporter? { lock.withLock { value } }
    func close(timeout: Double = 2) { existing()?.close(timeout: timeout) }
    func shutdown(timeout: Double = 2) async {
        await existing()?.shutdown(timeout: timeout)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
