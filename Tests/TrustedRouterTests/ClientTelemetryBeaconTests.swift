import Foundation
import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Beacon contract v1 tests. Inference calls use the repository-wide
/// MockURLProtocol recording fake; the client-events endpoint has a distinct
/// URLProtocol and URLSession so accidental reuse of the user's transport is
/// directly observable.
final class ClientTelemetryBeaconTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.mockError = nil
        BeaconEndpointProtocol.reset()
    }

    func testRealEngineUsesIsolatedBeaconAndEmitsPrivateSchemaOnly() async throws {
        let clock = BeaconClock(1)
        let router = try makeRouter(clock: clock, sampleRate: 1, maxRetries: 1)
        var engineRequests: [URLRequest] = []
        var statuses = [503, 200]
        MockURLProtocol.requestHandler = { request in
            engineRequests.append(request)
            let status = statuses.removeFirst()
            let headers = status == 503
                ? ["x-should-retry": "true"]
                : ["x-request-id": "rlog_0123456789abcdef0123456789abcdef"]
            return (
                Self.response(request, status: status, headers: headers),
                Data((status == 200 ? #"{"ok":true}"# : #"{"error":{"source":"router"}}"#).utf8)
            )
        }
        BeaconEndpointProtocol.script = [.init(status: 202, body: #"{"policy":{}}"#)]
        let prompt = "private prompt text which cannot enter telemetry"
        let result: [String: Bool] = try await router.request(
            method: "POST", path: "/responses",
            body: ["model": "model/a", "input": prompt],
            options: PerCallOptions(idempotencyKey: "private-idempotency-value")
        )
        XCTAssertEqual(result["ok"], true)
        XCTAssertEqual(engineRequests.count, 2)
        XCTAssertTrue(engineRequests.allSatisfy { $0.url?.path != "/v1/client-events" })
        let reporter = try XCTUnwrap(router.telemetryReporterStore?.existing())
        XCTAssertTrue(reporter.workerStarted)
        let flushed = await reporter.flushNow()
        XCTAssertTrue(flushed)
        XCTAssertEqual(BeaconEndpointProtocol.requests.count, 1)

        let request = try XCTUnwrap(BeaconEndpointProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://trustedrouter.com/v1/client-events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-trustedrouter-workspace"), "ws-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        let data = try XCTUnwrap(BeaconEndpointProtocol.bodies.first)
        XCTAssertLessThanOrEqual(data.count, 65_536)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains(prompt))
        XCTAssertFalse(encoded.contains("private-idempotency-value"))

        let batch = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(batch.keys), Set([
            "schema_version", "batch_id", "instance_id", "seq", "sent_at_ms", "sdk",
            "synthetic", "dropped_since_last", "events", "counters"
        ]))
        XCTAssertEqual((batch["batch_id"] as? String)?.count, 32)
        XCTAssertEqual((batch["instance_id"] as? String)?.count, 16)
        let events = try XCTUnwrap(batch["events"] as? [[String: Any]])
        let counters = try XCTUnwrap(batch["counters"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["sample_reason"] as? String, "retried")
        XCTAssertEqual((events[0]["attempts"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(counters.filter { $0["level"] as? String == "request" }.count, 1)
        XCTAssertEqual(counters.filter { $0["level"] as? String == "attempt" }.count, 2)
        router.close()
    }

    func testSamplingAndBoundedDropsAreDeterministic() {
        let reporter = makeReporter(sampleRate: 0, random: { 0.5 })
        reporter.record(event: event(outcome: "http_error"), counters: [])
        reporter.record(event: event(outcome: "ok"), counters: [])
        XCTAssertEqual(reporter.bufferedEventCount, 1, "failure is kept; healthy draw is rejected")

        let sampled = makeReporter(sampleRate: 1, apiKey: nil, random: { 0 })
        sampled.record(event: event(outcome: "ok"), counters: [])
        XCTAssertEqual(sampled.bufferedEventCount, 1)

        for index in 0..<1_000 {
            sampled.record(event: event(
                outcome: index == 0 ? "http_error" : "ok",
                model: "model-\(index)"
            ), counters: [])
        }
        XCTAssertEqual(sampled.bufferedEventCount, 1_000)
        XCTAssertEqual(sampled.droppedCount, 1)
        sampled.close(timeout: 0)
        reporter.close(timeout: 0)
    }

    func testExactCountersFoldAt256WithoutCountingADrop() {
        let reporter = makeReporter(sampleRate: 0, apiKey: nil)
        let endpoints = ClientTelemetry.endpoints
        let errors = ClientTelemetry.errorClasses
        let statuses = ["none", "2xx", "4xx", "429", "5xx"]
        var inserted = 0
        outer: for endpoint in endpoints {
            for error in errors {
                for status in statuses {
                    let key = counterKey(endpoint: endpoint, errorClass: error, statusClass: status)
                    reporter.record(event: event(outcome: "ok"), counters: [(key, increment())])
                    inserted += 1
                    if inserted == 257 { break outer }
                }
            }
        }
        let snapshot = reporter.currentCounterSnapshot
        XCTAssertEqual(snapshot.count, 256)
        XCTAssertEqual(snapshot.values.reduce(0) { $0 + $1.requests }, 257)
        XCTAssertTrue(snapshot.contains { $0.key.errorClass == "unknown" && $0.value.requests > 1 })
        XCTAssertEqual(reporter.droppedCount, 0, "folding is not dropping")
        reporter.close(timeout: 0)
    }

    func testFailedFlushRetainsWindowAnd429HonoursRetryAfter() async throws {
        let clock = BeaconClock(0)
        let reporter = makeReporter(clock: clock, sampleRate: 0)
        BeaconEndpointProtocol.script = [
            .init(status: 503), .init(status: 202),
            .init(status: 429, headers: ["Retry-After": "120"]), .init(status: 202)
        ]
        reporter.record(event: event(outcome: "ok"), counters: [(counterKey(), increment())])
        let firstFlush = await reporter.flushNow()
        XCTAssertFalse(firstFlush)
        clock.advance(120)
        let retainedFlush = await reporter.flushNow()
        XCTAssertTrue(retainedFlush)
        let retainedBatch = try Self.batch(at: 1)
        XCTAssertEqual(
            (retainedBatch["counters"] as? [[String: Any]])?.first?["window_start_age_ms"] as? Int,
            120_000
        )

        reporter.record(event: event(outcome: "http_error"), counters: [])
        let limitedFlush = await reporter.flushNow()
        XCTAssertFalse(limitedFlush)
        clock.advance(119)
        let earlyFlush = await reporter.flushNow()
        XCTAssertFalse(earlyFlush)
        XCTAssertEqual(BeaconEndpointProtocol.requests.count, 3)
        clock.advance(1)
        let recoveredFlush = await reporter.flushNow()
        XCTAssertTrue(recoveredFlush)
        XCTAssertEqual(BeaconEndpointProtocol.requests.count, 4)
        reporter.close(timeout: 0)
    }

    func testPermanentOffAndPolicyResponsesOnlyReduceVolume() async throws {
        let clock = BeaconClock(0)
        let policy = makeReporter(clock: clock, sampleRate: 0.5, flushSeconds: 30)
        BeaconEndpointProtocol.script = [
            .init(status: 202, body: #"{"policy":{"success_sample_rate":0.1,"flush_seconds":60,"pause_seconds":120}}"#),
            .init(status: 202, body: #"{"policy":{"success_sample_rate":0.9,"flush_seconds":1,"pause_seconds":0}}"#)
        ]
        policy.record(event: event(outcome: "http_error"), counters: [])
        let firstPolicyFlush = await policy.flushNow()
        XCTAssertTrue(firstPolicyFlush)
        XCTAssertEqual(policy.policySnapshot.0, 0.1)
        XCTAssertEqual(policy.policySnapshot.1, 60)
        policy.record(event: event(outcome: "http_error"), counters: [])
        let pausedFlush = await policy.flushNow()
        XCTAssertFalse(pausedFlush)
        clock.advance(120)
        let secondPolicyFlush = await policy.flushNow()
        XCTAssertTrue(secondPolicyFlush)
        XCTAssertEqual(policy.policySnapshot.0, 0.1)
        XCTAssertEqual(policy.policySnapshot.1, 60)

        let permanent = makeReporter()
        BeaconEndpointProtocol.script = [.init(status: 400)]
        permanent.record(event: event(outcome: "http_error"), counters: [])
        let permanentFlush = await permanent.flushNow()
        XCTAssertFalse(permanentFlush)
        XCTAssertTrue(permanent.isDisabled)
        XCTAssertEqual(permanent.bufferedEventCount, 0)

        let off = makeReporter()
        BeaconEndpointProtocol.script = [.init(status: 202, headers: ["x-tr-telemetry": "off"])]
        off.record(event: event(outcome: "http_error"), counters: [])
        let offFlush = await off.flushNow()
        XCTAssertTrue(offFlush)
        XCTAssertTrue(off.isDisabled)
        policy.close(timeout: 0)
        permanent.close(timeout: 0)
        off.close(timeout: 0)
    }

    func testSSEParserOwnsTTFTStreamFailureAndAbortHooks() async throws {
        let clock = BeaconClock(0)
        let success = makeReporter(clock: clock, sampleRate: 1)
        let recorder = RequestRecorder(
            streaming: true, reporter: success, endpoint: "responses", method: "POST",
            now: { clock.value() }
        )
        recorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        clock.advance(0.01)
        recorder.onResponse(statusCode: 200)
        clock.advance(0.19)
        let bytes = TrustedRouter.byteStream(from: Data("data: {\"value\":1}\n\ndata: [DONE]\n\n".utf8))
        let stream = makeDictionarySSEEvents(bytes: bytes, recorder: recorder)
        for try await _ in stream {}
        BeaconEndpointProtocol.script = [.init(status: 202)]
        let successFlush = await success.flushNow()
        XCTAssertTrue(successFlush)
        let successBatch = try Self.batch(at: 0)
        XCTAssertEqual(
            (successBatch["events"] as? [[String: Any]])?.first?["ttft_ms"] as? Int,
            200,
            "TTFT begins only when SSEParser returns its first event"
        )

        let brokenReporter = makeReporter(clock: clock, sampleRate: 1)
        let brokenRecorder = RequestRecorder(
            streaming: true, reporter: brokenReporter, endpoint: "responses", method: "POST",
            now: { clock.value() }
        )
        brokenRecorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        brokenRecorder.onResponse(statusCode: 200)
        let broken = makeDictionarySSEEvents(
            bytes: BrokenBeaconBytes().stream(), recorder: brokenRecorder
        )
        do {
            for try await _ in broken {}
            XCTFail("expected the scripted mid-body failure")
        } catch {}
        XCTAssertTrue(brokenReporter.currentCounterSnapshot.keys.contains {
            $0.level == "request" && $0.outcome == "stream_broken"
        })

        let abortedReporter = makeReporter(clock: clock, sampleRate: 1)
        let abortedRecorder = RequestRecorder(
            streaming: true, reporter: abortedReporter, endpoint: "responses", method: "POST",
            now: { clock.value() }
        )
        abortedRecorder.beginAttempt(baseURL: TrustedRouterConstants.defaultAPIBaseURL)
        abortedRecorder.onResponse(statusCode: 200)
        abortedRecorder.onAborted()
        abortedRecorder.finish()
        XCTAssertTrue(abortedReporter.currentCounterSnapshot.keys.contains {
            $0.level == "request" && $0.outcome == "aborted"
        })
        success.close(timeout: 0)
        brokenReporter.close(timeout: 0)
        abortedReporter.close(timeout: 0)
    }

    func testOptOutCreatesNoReporterAndCloseIsBounded() throws {
        var options = TrustedRouterOptions(telemetry: false)
        let beaconConfig = URLSessionConfiguration.ephemeral
        beaconConfig.protocolClasses = [BeaconEndpointProtocol.self]
        options.telemetryURLSession = URLSession(configuration: beaconConfig)
        let off = try TrustedRouter(options: options)
        XCTAssertNil(off.telemetryReporterStore)

        let reporter = makeReporter()
        reporter.record(event: event(outcome: "http_error"), counters: [])
        BeaconEndpointProtocol.script = [.init(status: 202, delay: 5)]
        let started = ProcessInfo.processInfo.systemUptime
        reporter.close(timeout: 0.2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    }

    // MARK: fixtures

    private func makeRouter(
        clock: BeaconClock,
        sampleRate: Double,
        maxRetries: Int
    ) throws -> TrustedRouter {
        let engineConfig = URLSessionConfiguration.ephemeral
        engineConfig.protocolClasses = [MockURLProtocol.self]
        let beaconConfig = URLSessionConfiguration.ephemeral
        beaconConfig.protocolClasses = [BeaconEndpointProtocol.self]
        var options = TrustedRouterOptions(
            apiKey: "sk-test", urlSession: URLSession(configuration: engineConfig),
            workspaceId: "ws-test", maxRetries: maxRetries, regionalFailover: true,
            telemetry: true, telemetrySampleRate: sampleRate, regionalAffinity: false
        )
        options.telemetryURLSession = URLSession(configuration: beaconConfig)
        options.telemetryClock = { clock.value() }
        options.telemetryWallClock = { 1_700_000_000 }
        options.telemetryRandom = { 0 }
        options.telemetryFlushSeconds = 600
        return try TrustedRouter(options: options)
    }

    private func makeReporter(
        clock: BeaconClock = BeaconClock(1),
        sampleRate: Double = 1,
        apiKey: String? = "sk-test",
        flushSeconds: Double = 600,
        random: @escaping @Sendable () -> Double = { 0 }
    ) -> TelemetryReporter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BeaconEndpointProtocol.self]
        return TelemetryReporter(
            controlBaseURL: TrustedRouterConstants.defaultControlBaseURL,
            apiKey: apiKey, workspaceID: nil, successSampleRate: sampleRate,
            flushSeconds: flushSeconds, session: URLSession(configuration: config),
            clock: { clock.value() }, wallClock: { 1_700_000_000 }, random: random
        )
    }

    private func event(outcome: String, model: String? = "model/a") -> TelemetryRequestEvent {
        let attempt = TelemetryAttemptRecord(
            index: 0, host: "apex", outcome: outcome,
            httpStatus: outcome == "ok" ? 200 : 503,
            errorClass: nil, errorSource: nil, shouldRetry: nil,
            retryAfterMs: nil, elapsedMs: 25, ttfbMs: 20,
            requestID: nil, moved: false
        )
        return TelemetryRequestEvent(
            endpoint: "responses", method: "POST", streaming: false,
            providerPinned: false, model: model, attempts: [attempt],
            finalOutcome: outcome, finalHTTPStatus: attempt.httpStatus,
            totalMs: 25, ttftMs: nil, failoverUsed: false,
            timeoutPhase: "none", configuredTimeoutMs: nil, completedAt: 1
        )
    }

    private func counterKey(
        endpoint: String = "responses",
        errorClass: String? = nil,
        statusClass: String = "2xx"
    ) -> TelemetryCounterKey {
        TelemetryCounterKey(
            level: "request", endpoint: endpoint, streaming: false,
            host: "apex", outcome: "ok", errorClass: errorClass,
            httpStatusClass: statusClass, timeoutPhase: "none",
            timeoutFloorMet: false, providerPinned: false
        )
    }

    private func increment() -> TelemetryCounterIncrement {
        TelemetryCounterIncrement(
            requests: 1, attempts: 1, firstAttemptSuccess: 1,
            totalMsHistogram: ["lt100": 1], firstEventMsHistogram: ["lt100": 1]
        )
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://invalid.local")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
    }

    private static func batch(at index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(BeaconEndpointProtocol.bodies.indices.contains(index)
            ? BeaconEndpointProtocol.bodies[index] : nil)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class BeaconClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double
    init(_ value: Double) { stored = value }
    func value() -> Double { lock.lock(); defer { lock.unlock() }; return stored }
    func advance(_ seconds: Double) { lock.lock(); stored += seconds; lock.unlock() }
}

private struct BeaconResponse {
    var status: Int
    var body: String = #"{"policy":{}}"#
    var headers: [String: String] = [:]
    var delay: Double = 0
}

private final class BeaconEndpointProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: [BeaconResponse] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() { script = []; requests = []; bodies = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.readBody(request))
        let item = Self.script.isEmpty ? BeaconResponse(status: 202) : Self.script.removeFirst()
        let respond = { [self] in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: item.status,
                httpVersion: "HTTP/1.1", headerFields: item.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(item.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if item.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + item.delay, execute: respond)
        } else {
            respond()
        }
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class BrokenBeaconBytes: @unchecked Sendable {
    private let data = Data("data: {\"value\":1}\n\n".utf8)
    private var index = 0
    func stream() -> TrustedRouterByteStream {
        TrustedRouterByteStream(unfolding: { [self] in
            if index < data.count {
                defer { index += 1 }
                return data[index]
            }
            throw URLError(.networkConnectionLost)
        })
    }
}
