# Changelog

All notable changes to this SDK are documented here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[Semantic Versioning](https://semver.org/).

## 0.7.0 — 2026-08-21

### Added
- Content-free client reliability telemetry, header channel only
  (client-telemetry contract v1): every inference-plane attempt carries an
  `x-tr-client` header describing the attempt index, the previous attempt's
  outcome/class/host/timing, streaming, and failover use. Configured with the
  new `TrustedRouterOptions.telemetry` option, honouring the documented
  `TRUSTEDROUTER_TELEMETRY` > `DO_NOT_TRACK` precedence, defaulting on only
  for known TrustedRouter hosts. Custom base URLs and control-plane calls
  never send it; the beacon channel is deliberately deferred per the
  contract's rollout order.
- `x-tr-client` is SDK-reserved: a caller-supplied value is stripped from
  every header layer the SDK merges, and because a header set in an injected
  session's `URLSessionConfiguration.httpAdditionalHeaders` is merged by the
  URL loading system after the request leaves the SDK — where it cannot be
  stripped — constructing a `TrustedRouter` with such a session now throws
  rather than letting the value ride requests the SDK did not describe. Only
  this one field name is rejected; any other session default header is
  untouched. To turn telemetry off use `TrustedRouterOptions.telemetry`,
  `TRUSTEDROUTER_TELEMETRY=0`, or `DO_NOT_TRACK=1`.
- Alias-domain failover: when the default API host stops answering, requests
  fail over to `api.allyrouter.com` and `api.uptimerouter.com` — exact aliases
  of `api.trustedrouter.com` on separate domains and separate DNS providers,
  resolving to the same attested enclaves. They sit at the tail of the
  candidate list, so a healthy deployment never uses them, and they are
  appended only for the default API host — a custom base URL is never
  rewritten. Clients with an injected `URLSession`, and a regional health race
  that no region wins, previously collapsed to a single host (exactly when
  failover was needed) and now keep the primary-plus-aliases list. Documented
  in the README. (#6, #7)
- The gateway's `x-should-retry` response header is honoured: a 5xx it labels
  non-retryable stays on its host (the inference already ran once; re-sending
  it would pay the upstream provider again and could return a different
  answer), and a labelled-retryable 4xx is retried. `retry-after-ms` is parsed
  and wins over `retry-after`. (#8)
- `SECURITY.md` (private vulnerability reporting, acknowledged within 72
  hours) and `CODEOWNERS`.

### Changed
- **Visible change:** the User-Agent now matches the contract §3.1 grammar
  (`trusted-router-swift/SEMVER runtime/ver`, for example
  `trusted-router-swift/0.7.0 macos/14.6.1` where 0.6.1 sent
  `trusted-router-swift/0.6.1 (macOS 14.6)`): the old parenthesised suffix
  fell outside the grammar the enclave parses, so the runtime information was
  silently dropped server-side.
- `regionalFailover: false` now means "stay on one host": transport errors
  and failoverable statuses are still retried, in place, instead of the flag
  disabling retries altogether. (#8)
- One transport engine: the three hand-copied retry/failover loops were
  replaced by a single `withTransportRetries` loop (the only candidate-advance
  and sleep site), and the sources moved into layered directories inside the
  same SwiftPM target. Public API, module name, and import paths are
  unchanged. The streaming byte wrapper is now lazy, so retried attempts drop
  their payloads without leaking reader tasks. (#9)

### Fixed
- SSE parsing and typed/dictionary/text adapters are now pull-driven instead
  of feeding unbounded `AsyncThrowingStream` continuation queues. Frames are
  capped at 1 MiB. Darwin uses live `URLSession.AsyncBytes`; Linux's
  `FoundationNetworking` limitation is explicit: it buffers the response
  before the SDK performs demand-driven replay.
- URLSession redirects and HTTP authentication follow-ups are blocked. SDK
  sends use a configuration clone without the caller's ambient session
  delegate or credential store, and the per-task delegate cancels non-TLS
  challenges. TLS server-trust evaluation still uses Foundation's default
  handler; a blocked 401/407 is restored to the normal SDK status classifier
  without becoming a retryable cancellation error. The clone retains protocol
  classes, proxies, cache/timeouts, benign headers, and cookies, but deliberately
  does not retain delegate-based private-CA, pinning, mTLS, or auth behavior.
- Public status, attestation, trust-release, JWKS, and regional-health requests
  now receive a final credential-header scrub in addition to their isolated
  cookie and credential stores. Authorization, proxy authorization, cookies,
  API keys, workspace/idempotency fields, and `x-tr-client` are withheld while
  benign tracing defaults remain.
- Header layers now merge case-insensitively, so an override like
  `User-Agent` or `Authorization` supplied in a different casing than the
  SDK's lowercase keys deterministically wins by layer precedence
  (built-ins < client defaults < per-call headers < extra headers <
  computed) instead of depending on dictionary iteration order against
  `URLRequest`'s case-insensitive header store. Layers apply in sorted key
  order, so even two case-variants inside one dictionary resolve
  deterministically. A caller-supplied authorization header in any casing
  still suppresses the API-key-derived one.
- `Retry-After` is bounded at 60 seconds, matching the other SDKs. Swift's
  `Double("inf")` parses to `.infinity` and `UInt64(Double)` traps on it, so a
  single `Retry-After: inf` response header terminated the process — on iOS,
  an app crash driven by a response header. The backoff exponent is clamped
  too, closing a trap that needed no header at all. (#10)
- An attestation policy that pins no image identity is refused. Both image
  checks short-circuited on an empty accepted list, and building a policy from
  a degraded trust release produced exactly that: a populated
  `GatewayAttestation` whose image digest was the workload's own self-declared
  value. The policy builder and the verifier now both fail closed. (#11)

## 0.6.1 — 2026-08-08

### Fixed
- Accept the published attestation rollout signing-key pins while preserving
  verification of the prior production pins during rotation.

## 0.6.0 — 2026-08-01

### Changed
- Default inference base URL is now `https://api.trustedrouter.com/v1`.
- Regional failover now re-requests the apex global load balancer; per-region
  inference hostnames were removed.
- Added `TrustedRouterConstants.defaultControlBaseURL` and the
  `TrustedRouterOptions.controlBaseURL` override for control-plane routes.
- Routed catalog, provider/region, credits, activity, auth/OAuth, billing,
  and broadcast-destination calls to the control plane while keeping chat,
  messages, responses, embeddings, input-token estimation, and attestation on
  the inference plane.

## 0.4.0 — 2026-05-10

### Added
- Strongly-typed `ChatMessage` with `.user(_:)` / `.assistant(_:)` /
  `.system(_:)` / `.tool(callId:content:)` conveniences.
- `[ChatMessage]` overloads for `chatCompletions(...)` and
  `chatCompletionsChunks(...)`, so call sites don't have to drop down to
  `[[String: Any]]` for typed conversations.
- Streaming endpoints now drain the response body when the HTTP status is
  ≥ 400 and surface it through the regular `TrustedRouterError`
  classifier — the server's actual message reaches the caller instead of
  a generic "Error in stream response".
- `DER` namespace: extracted PKCS#1 RSAPublicKey assembly out of
  `Attestation.swift` into its own file with unit tests. The signature
  verification path is unchanged on the wire.
- User-Agent now reports the host OS and version
  (e.g. `trusted-router-swift/0.4.0 (macOS 26.4)`).
- Comprehensive test suite: 6 tests → **67 tests** (55 new in this
  release, 6 added in 0.3.3). Coverage now includes
  every status-code classification path, retry-after honoring, retry
  exhaustion, every Codable model (snake_case ↔ camelCase), every SSE
  parser frame-boundary form (LF-LF and CRLF-CRLF), the multi-byte UTF-8
  byte-split-boundary regression (fixed in 0.3.2), the `[DONE]` sentinel,
  DER encoding edge cases (leading-zero strip, high-bit padding,
  short/long-form length), and a real JWT signed-then-verified round-trip
  plus a tampered-signature rejection test.

### Changed
- `TrustedRouterConstants` is now an `enum` (uninstantiable namespace)
  rather than a `struct`.
- Trailing-slash stripping in the constructor uses a clearer loop instead
  of a no-op regex.
- DocC comments added to all top-level public types.

### Fixed
- Nothing functional in this release; 0.3.2 fixed the UTF-8 byte-drop and
  the missing-RSA-verify gaps.

## 0.3.3 — earlier

### Added
- More endpoint coverage in `TrustedRouterEndpointTests` (providers,
  credits, billing, broadcast destinations); `nonisolated(unsafe)`
  annotations on the mock-protocol storage; `SimpleAsyncBytes` helper.

## 0.3.2

### Fixed
- SSE parser dropped multi-byte UTF-8 characters that crossed network-
  buffer boundaries; switched to byte-buffered framing with decode at
  frame boundary.
- `verifyGatewayAttestation` now actually verifies the JWT signature via
  `SecKeyVerifySignature` with a hand-rolled PKCS#1 DER assembly from
  the JWK's n/e parameters.

## 0.3.1

### Changed
- Typed `Decodable` response models replaced `[String: Any]` returns.
- `iterSseEvents` got a generic typed variant.

## 0.3.0

### Added
- Initial implementation: endpoints, streaming, attestation scaffold,
  Confidential Space JWT support.
