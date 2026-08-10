import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L3 — TRANSPORT ENGINE. THE single retry/failover loop. This is the ONLY
// place in the codebase where the candidate index advances and the ONLY
// place that sleeps. Every request mode rides it through a thin
// `sendAttempt` adapter: buffered (`request<T>` via `data(for:)`) and
// stream-open (`rawStreamRequest` via `bytes(for:)` on Darwin /
// buffered-replay on Linux). The engine never drains a success body — that
// is what lets streaming share it — and never retries after the first
// surfaced body byte. `rawRequest` is public and single-shot by contract;
// it does not ride the loop.
//
// INVARIANTS (each line names its enforcing test):
//  (1) Failover set {502,503,504} is a strict subset of the retry set
//      {429, 502, 503, 504, verdict-true}.
//      — testFailoverableStatusMovesToAnotherDomainAndCanSucceed,
//        test429MapsToRateLimitAndCarriesRetryAfter
//  (2) 500 NEVER moves domains — a server processed the non-idempotent
//      inference; re-sending elsewhere risks a second generation.
//      — testA500DoesNotMoveToAnotherDomain, test500DoesNotFailoverRetry
//  (3) Aliases exist only for the default host; the control plane always has
//      an empty candidate list here, so failover is structurally impossible;
//      custom bases are never redirected.
//      — testACustomBaseURLIsNeverRedirectedToAPublicAlias,
//        testDisablingRegionalFailoverPinsTheClientToOneHost
//  (4) x-should-retry overrides both predicates in both directions.
//      — testALabelledSpent502IsNotRetriedAndDoesNotMoveDomains,
//        testALabelledRetryable400IsRetried, testAnUnlabelled502StillFailsOver
//  (5) Idempotency key minted once per logical call BEFORE the loop and
//      re-sent verbatim across every attempt and domain move.
//      — testRegionalAffinityPinsFastestAndFailsOverWithSameIdempotencyKey
//  (6) Retries happen only before any body bytes are surfaced; a broken open
//      stream propagates, never reconnects.
//      — testChatCompletionsChunksMovesFailoverableStatusToAnAliasDomain
//  (7) regionalFailover governs WHERE, never WHETHER — a pinned client still
//      retries in place.
//      — testAPinnedClientStillRetriesInPlace,
//        testFailoverableStatusRetriesInPlaceWhenRegionalFailoverDisabled,
//        testTransportErrorRetriesInPlaceWhenRegionalFailoverDisabled
//  (8) Transport errors (no server saw the request) may always move hosts
//      within the flag gating; HTTP moves additionally require a
//      failoverable status; a provider 429 stays pinned to its region.
//      — testTransportErrorMovesToAnAliasDomainWhenRegionalFailoverEnabled,
//        testRegionalAffinityKeepsPinnedRegionForProvider429
//  (9) Terminal asymmetry: an exhausted HTTP status RETURNS `(payload, http)`
//      for the caller to classify — `request<T>` classifies-and-throws on
//      >=400 while `rawStreamRequest` returns the non-200 stream for the
//      caller to drain — but transport exhaustion THROWS `.internalError`.
//      — testChatCompletionsChunks401ContainsServerMessage,
//        test429MapsToRateLimitAndCarriesRetryAfter
// (10) The deliberately-unreachable verdict-false guard inside
//      `RetryPolicy.isFailoverableStatus` is a documented surviving mutant.
extension TrustedRouter {

    /// Drives one logical call through retries and candidate-domain failover.
    ///
    /// `sendAttempt` performs exactly one wire attempt and returns the raw
    /// payload plus its `HTTPURLResponse`. It must not loop, sleep, or retry;
    /// it must surface transport failures as thrown non-`TrustedRouterError`
    /// errors (pre-flight `TrustedRouterError`s are rethrown, never retried).
    func withTransportRetries<Payload>(
        method: String,
        path: String,
        plane: TrustedRouterRequestPlane,
        headers: [String: String]?,
        body: Data?,
        options: PerCallOptions,
        sendAttempt: (URLRequest) async throws -> (Payload, HTTPURLResponse)
    ) async throws -> (Payload, HTTPURLResponse) {
        // (Invariant 5) The idempotency key is minted ONCE, before the loop,
        // and only for relative inference-plane mutations. Control-plane
        // POSTs (billingCheckout, broadcast CRUD) intentionally get no
        // auto-minted key.
        var effectiveOptions = options
        let inference = usesInferenceBase(path: path, plane: plane)
        if inference,
           effectiveOptions.idempotencyKey == nil,
           !["GET", "HEAD", "OPTIONS"].contains(method.uppercased()) {
            effectiveOptions.idempotencyKey = "tr-req-\(UUID().uuidString)"
        }

        var attempt = 0
        var candidateIndex = 0
        // (Invariant 3) Resolved ONCE per logical call, never mid-loop. The
        // control plane and absolute fetches get an empty list, which makes
        // the advance below structurally unreachable for them.
        let candidates = inference ? await inferenceBaseURLs() : []

        while true {
            let selectedBaseURL = candidates.isEmpty ? nil : candidates[candidateIndex]
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
                options: effectiveOptions,
                body: body
            )

            let retryAfterSeconds: Double?
            let mayMoveHost: Bool
            do {
                let (payload, http) = try await sendAttempt(request)
                guard attempt < maxRetries,
                      RetryPolicy.shouldRetry(
                          statusCode: http.statusCode,
                          path: path,
                          plane: plane,
                          response: http
                      )
                else {
                    // (Invariant 9) Exhausted or non-retryable HTTP outcomes
                    // are RETURNED, never thrown: callers keep their divergent
                    // terminal behaviour.
                    return (payload, http)
                }
                retryAfterSeconds = RetryPolicy.parseRetryAfter(http)
                // (Invariants 2, 8) An HTTP move additionally requires a
                // failoverable status: 500 and 429 retry in place.
                mayMoveHost = RetryPolicy.isFailoverableStatus(http.statusCode, http)
            } catch let err as TrustedRouterError {
                // Pre-flight failures (invalid URL, non-HTTP response) are
                // never retried.
                throw err
            } catch {
                guard attempt < maxRetries,
                      RetryPolicy.shouldRetryTransportError(path: path, plane: plane)
                else {
                    throw TrustedRouterError.internalError(error.localizedDescription)
                }
                retryAfterSeconds = nil
                // (Invariant 8) No server saw the request, so moving is always
                // safe — only the flag and the list bound gate it below. This
                // asymmetry with the HTTP branch is load-bearing.
                mayMoveHost = true
            }

            // THE single advance site (invariant 7: the flag gates WHERE only).
            if regionalFailover, mayMoveHost, candidateIndex < candidates.count - 1 {
                candidateIndex += 1
            }
            // The single sleep site.
            try await Task.sleep(nanoseconds: RetryPolicy.retrySleepMs(
                attempt: attempt,
                retryAfterSeconds: retryAfterSeconds
            ))
            attempt += 1
        }
    }

    /// Per-attempt request assembly (L4): URL, method, body, timeout shaping,
    /// default + per-call headers, Bearer/workspace headers, and content-type
    /// defaulting. Shared by the engine, `rawRequest`, and nothing else.
    func buildURLRequest(
        method: String,
        url: URL,
        headers: [String: String]?,
        options: PerCallOptions,
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let timeout = options.timeout {
            request.timeoutInterval = timeout
        }
        let requestHeaders = buildHeaders(
            headers: headers,
            extraHeaders: options.extraHeaders,
            idempotencyKey: options.idempotencyKey,
            apiKey: options.apiKey,
            workspaceId: options.workspaceId
        )
        for (name, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if body != nil && request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Downcast guard shared by every sendAttempt adapter.
    static func httpOnly(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TrustedRouterError.internalError("Non-HTTP response")
        }
        return http
    }
}
