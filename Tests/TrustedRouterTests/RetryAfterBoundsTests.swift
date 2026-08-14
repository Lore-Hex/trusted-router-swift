import XCTest
@testable import TrustedRouter

/// Property tests for the Retry-After bound.
///
/// Retry-After arrives from whatever answered the socket — the gateway, a
/// proxy, an alias domain — so it is untrusted input, and it was applied as an
/// *uncapped* floor on the backoff sleep. The law:
///
///     for every attempt a and every header value v,
///         boundedRetryAfter(v)  is nil, or finite and in 0...maxRetryAfterSeconds
///         retrySleepMs(a, ..)   is <= maxRetryAfterSeconds * 1000 * 1_000_000 ns
///
/// This SDK had the most severe instance of the defect of any of the six, and
/// the reason is a Swift language behaviour rather than a logic slip:
///
///   * `Double.init?(String)` is far more permissive than the RFC 7231 grammar.
///     "inf", "Inf", "infinity", "Infinity" and "+inf" all parse to `.infinity`,
///     and "1e400" silently overflows to it. The old `millis >= 0` test passes
///     for `.infinity`.
///
///   * `UInt64(Double)` **traps** on an infinite or out-of-range value. That is
///     a Swift runtime fatal error, not a catchable Swift error — there is no
///     `try` that helps and no `do/catch` that contains it.
///
/// Measured on Swift 6.0.3 by executing the verbatim body of `retrySleepMs`: a
/// single `Retry-After: inf` response terminated the process with SIGTRAP
/// (exit 133). On iOS that is an app crash driven by a response header, from a
/// value any proxy in the path can set.
///
/// Because the pre-fix failure is a process trap, these tests cannot exercise
/// it directly — a crashing test takes the whole runner with it. They assert
/// the post-fix law instead, and the specific values that used to trap are
/// enumerated explicitly so the regression surface is named rather than
/// implied.
///
/// Mirrors `tests/test_retry_after_bounds.py`, `test/retry-after-bounds.test.js`,
/// `retry_after_bounds_test.go`, the Rust `retry_after_bound_tests` module and
/// `RetryAfterBoundsPropertyTest.java`.
final class RetryAfterBoundsTests: XCTestCase {

    private let ceilingNs = UInt64(RetryPolicy.maxRetryAfterSeconds * 1000.0 * 1_000_000)

    /// Header strings a hostile or broken peer can actually send. The first
    /// group is what Swift's permissive Double parser turns into `.infinity`.
    private let hostileHeaders = [
        "inf", "Inf", "INF", "infinity", "Infinity", "+inf", "+Infinity",
        "-inf", "-Infinity", "nan", "NaN", "1e400", "1e309",
        "1e300", "100000", "86400", "-5", "-0.001", "0", "0.5", "30",
        "59.999", "60", "60.001", "  30  ", "30s", "", "   ",
        "Wed, 21 Oct 2015 07:28:00 GMT",
    ]

    private func response(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.trustedrouter.com/v1/chat/completions")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: - the law

    func testAParsedHintIsAlwaysFiniteAndBounded() {
        for raw in hostileHeaders {
            for name in ["retry-after", "retry-after-ms"] {
                guard let parsed = RetryPolicy.parseRetryAfter(response([name: raw])) else {
                    continue
                }
                XCTAssertTrue(parsed.isFinite, "\(name): \(raw) produced \(parsed)")
                XCTAssertGreaterThanOrEqual(parsed, 0, "\(name): \(raw)")
                XCTAssertLessThanOrEqual(
                    parsed, RetryPolicy.maxRetryAfterSeconds, "\(name): \(raw) is unbounded")
            }
        }
    }

    func testTheSleepThatReachesTaskSleepIsAlwaysBounded() {
        // Attempt is quantified too: pow(2.0, Double(attempt)) is +infinity for
        // a large attempt, so this is an overflow path with no header involved.
        let attempts = [0, 1, 5, 16, 17, 63, 64, 1024, 100_000, Int.max, -1]
        for raw in hostileHeaders {
            for attempt in attempts {
                let hint = RetryPolicy.parseRetryAfter(response(["retry-after": raw]))
                let ns = RetryPolicy.retrySleepMs(attempt: attempt, retryAfterSeconds: hint)
                XCTAssertLessThanOrEqual(
                    ns, ceilingNs, "\(raw) at attempt \(attempt) produced \(ns) ns")
            }
        }
    }

    func testRetrySleepMsReclampsAHintHandedToItDirectly() {
        // retrySleepMs is reachable without going through the parser, and this
        // is the call that traps, so the bound has to live here too.
        let hints: [Double?] = [
            .infinity, -.infinity, .nan, .greatestFiniteMagnitude,
            1e300, 1e9, 100_000, -5, 0, 30, 60, 60.001, nil,
        ]
        for hint in hints {
            let ns = RetryPolicy.retrySleepMs(attempt: 0, retryAfterSeconds: hint)
            XCTAssertLessThanOrEqual(ns, ceilingNs, "direct hint \(String(describing: hint))")
        }
    }

    // MARK: - the values that used to terminate the process

    func testTheHeadersThatUsedToTrapAreRejected() {
        // Each of these parsed to .infinity and then trapped in UInt64(Double).
        for raw in ["inf", "Inf", "INF", "infinity", "Infinity", "+inf", "1e400", "1e309"] {
            XCTAssertNil(
                RetryPolicy.parseRetryAfter(response(["retry-after": raw])),
                "\(raw) must not survive parsing")
        }
    }

    func testNonFiniteAndNegativeHintsAreRejectedByTheBound() {
        XCTAssertNil(RetryPolicy.boundedRetryAfter(.infinity))
        XCTAssertNil(RetryPolicy.boundedRetryAfter(-.infinity))
        XCTAssertNil(RetryPolicy.boundedRetryAfter(.nan))
        XCTAssertNil(RetryPolicy.boundedRetryAfter(-5))
    }

    func testTheHeadersThatUsedToParkACallerAreClamped() {
        for raw in ["1e300", "100000", "86400"] {
            XCTAssertEqual(
                RetryPolicy.parseRetryAfter(response(["retry-after": raw])),
                RetryPolicy.maxRetryAfterSeconds,
                "\(raw) should clamp to the ceiling")
        }
    }

    // MARK: - what the bound must not disturb

    func testHintsWithinTheBoundAreHonouredExactly() {
        for seconds in [0.0, 0.25, 1, 30, 59, 60] {
            XCTAssertEqual(RetryPolicy.boundedRetryAfter(seconds), seconds)
            let ns = RetryPolicy.retrySleepMs(attempt: 0, retryAfterSeconds: seconds)
            XCTAssertGreaterThanOrEqual(
                ns, UInt64(seconds * 1000 * 1_000_000),
                "a hint inside the bound must still act as a floor")
        }
    }

    func testAJunkMillisecondHeaderFallsThroughToSeconds() {
        for junk in ["inf", "nan", "-5", "abc"] {
            XCTAssertEqual(
                RetryPolicy.parseRetryAfter(
                    response(["retry-after-ms": junk, "retry-after": "7"])),
                7,
                "retry-after-ms \(junk) should fall through")
        }
    }

    func testTheMillisecondHeaderStillWinsWhenUsable() {
        XCTAssertEqual(
            RetryPolicy.parseRetryAfter(
                response(["retry-after-ms": "1500", "retry-after": "7"])),
            1.5)
    }

    func testTheCeilingStaysInsideUInt64Range() {
        // The reason the clamp is safe to apply before the UInt64 conversion.
        XCTAssertLessThan(Double(ceilingNs), Double(UInt64.max))
    }
}
