import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L1 — POLICY KERNEL. Pure decision functions: no I/O, no clock, no state.
// The transport engine (Transport/TransportEngine.swift) is the ONLY caller
// that acts on these verdicts, the only place a candidate index advances,
// and the only place that sleeps.
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
//      exactly one candidate (an empty candidate list in the engine); custom
//      bases are never redirected.
//      — testACustomBaseURLIsNeverRedirectedToAPublicAlias,
//        testDisablingRegionalFailoverPinsTheClientToOneHost
//  (4) x-should-retry overrides both predicates in both directions: explicit
//      false forbids retry AND failover; explicit true forces retry;
//      absent/unparseable keeps the status heuristics.
//      — testALabelledSpent502IsNotRetriedAndDoesNotMoveDomains,
//        testALabelledRetryable400IsRetried, testAnUnlabelled502StillFailsOver
//  (5) Idempotency key minted once per logical call before the loop and
//      re-sent verbatim across every attempt and domain move — the caller is
//      never double-charged (idempotent auth + exactly-once settlement).
//      — testRegionalAffinityPinsFastestAndFailsOverWithSameIdempotencyKey
//  (6) Retries happen only before any body bytes are surfaced; a broken open
//      stream propagates, never reconnects.
//      — testChatCompletionsChunksMovesFailoverableStatusToAnAliasDomain
//        (the retry decision is made on the opened response's status, before
//        the byte stream is handed to the caller)
//  (7) The regionalFailover flag governs WHERE, never WHETHER — a pinned
//      client still retries in place.
//      — testAPinnedClientStillRetriesInPlace,
//        testFailoverableStatusRetriesInPlaceWhenRegionalFailoverDisabled,
//        testTransportErrorRetriesInPlaceWhenRegionalFailoverDisabled
//  (8) Transport errors (no server saw the request) may always move hosts
//      within the flag gating; HTTP moves additionally require a
//      failoverable status. A provider 429 retries in place.
//      — testTransportErrorMovesToAnAliasDomainWhenRegionalFailoverEnabled,
//        testRegionalAffinityKeepsPinnedRegionForProvider429
//  (9) Terminal asymmetries are contract: an exhausted HTTP status RETURNS
//      the response for the caller to classify (request<T> throws a typed
//      error; rawStreamRequest hands back the non-200 stream to drain), while
//      transport exhaustion THROWS `.internalError`.
//      — testChatCompletionsChunks401ContainsServerMessage,
//        test429MapsToRateLimitAndCarriesRetryAfter
// (10) The deliberately-unreachable verdict-false guard inside
//      `isFailoverableStatus` is a documented surviving mutant — kept
//      verbatim, never "fixed", never tested. See the comment on the
//      function itself.
enum RetryPolicy {

    static func header(_ response: HTTPURLResponse, _ name: String) -> String? {
        for candidate in [name, name.lowercased(), name.capitalized] {
            if let raw = response.allHeaderFields[candidate] as? String { return raw }
        }
        return nil
    }

    static func parseRetryAfter(_ response: HTTPURLResponse) -> Double? {
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
    static func shouldRetryVerdict(_ response: HTTPURLResponse) -> Bool? {
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
    static func isFailoverableStatus(_ statusCode: Int, _ response: HTTPURLResponse?) -> Bool {
        if let response, shouldRetryVerdict(response) == false { return false }
        return statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    /// Whether we may send this again — independent of WHERE it goes.
    ///
    /// This used to require `regionalFailover` for 502/503/504, so pinning to
    /// one host ALSO stopped retrying the gateway statuses entirely: one switch
    /// answering two questions. The flag now governs only the destination.
    static func shouldRetry(
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
    static func shouldRetryTransportError(path: String, plane: TrustedRouterRequestPlane) -> Bool {
        return usesInferenceBase(path: path, plane: plane)
    }

    /// Jittered exponential backoff (500ms base, 30s cap), floored by any
    /// server-supplied retry-after. Pure: the transport engine is the only
    /// place that actually sleeps on this value.
    static func retrySleepMs(attempt: Int, retryAfterSeconds: Double?) -> UInt64 {
        let baseMs = min(30_000, 500 * pow(2.0, Double(attempt)))
        let jittered = Double.random(in: 0...baseMs)
        let floor = (retryAfterSeconds ?? 0) * 1000.0
        return UInt64(max(jittered, floor) * 1_000_000)
    }
}
