# Boundary audit

Initial inventory, recorded before implementation edits. Line numbers in this table refer to the original checkout. The final verification section records current locations and outcomes.

| Class | Original source site (under Sources/TrustedRouter) | Verdict / rationale |
|---|---|---|
| Force unwrap | Attestation/Attestation.swift:403 | Already-safe UTF-8 conversion; replace with total Data initializer. |
| Force unwrap | Endpoints/TrustedRouter+Chat.swift:238,241 | Already-safe: keys come from the same unchanged local dictionaries; name invariants inline. |
| Force unwrap | Streaming/ByteStream.swift:104 | Already-safe: iterator initialized immediately above; name invariant inline. |
| Force unwrap | Receipts/ReceiptVerification.swift:661,664,1069 | Already-safe: nil excluded by preceding short-circuit conditions; replace with optional operations. |
| Force unwrap | OAuth/OAuthLoopback.swift:351 | Already-safe at current callers (nonempty HTTP response literals); remove the force operation with an optional buffer base address so empty future writes are harmless. |
| Force cast | Core/TrustedRouterClient.swift:468 | Already-safe exact runtime type comparison; use conditional cast. |
| Force cast | Transport/SecureURLSession.swift:73,138 | Already-safe Foundation NSCopying contract; use configuration getter (already returns a copy). |
| Force try / IUO | Whole Sources tree | None. |
| Byte indexing | Attestation/DER.swift:20,23 | Fixed: Data may have a nonzero startIndex, particularly after removeFirst; use Array for integer normalization. |
| Byte indexing | Attestation/Attestation.swift:129–131,388–390 | Already-safe: explicit count bounds and three-segment check. |
| Byte indexing | Attestation/AttestedSession.swift:213 | Already-safe: statusParts.count >= 2. |
| Byte indexing | OAuth/OAuth.swift:80,144–184; OAuth/OAuthLoopback.swift:334 | Already-safe: allocated lengths, padded SHA blocks, fixed schedule bounds; recv cannot exceed buffer length. |
| Byte indexing | Receipts/ReceiptVerification.swift:139–306,355–356,417,650,683 | Scanner offsets, three-segment checks and equality bounds are safe. Final review found the caller-supplied SSE Data-slice case at findSequence; fixed below. |
| Array indexing | Transport/TransportEngine.swift:111; Telemetry/ClientTelemetry.swift:627; Telemetry/BeaconReporter.swift:777 | Already-safe: candidate index starts at zero and advances modulo count; phase index checked; removal only with nonempty events. |
| Pass-through Codable | OAuth/OAuth.swift:198–329 | Fixed: preserve unknown OAuth fields; UserInfo.sub optional for legacy null. Exchange data optional but must be an object when present. Company affiliations remain optional, including unknown affiliation metadata. |
| Other Codable | Models/Models.swift:5–394; Models/ChatMessage.swift:7–48 | Intentionally unchanged: existing endpoint contracts require data/id/choices/usage counts/role/model as declared. No producer fixture proves these requirements false. Optional metadata uses decodeIfPresent and rejects wrong types. Request ChatMessage is caller-owned. JSONValue tries alternative JSON types, then throws rather than laundering failure. |
| Consumed defaults | Attestation/Attestation.swift:204–209 | Fixed: malformed present trust-release image strings/lists must not disappear behind another valid pin. Missing fields remain allowed, with existing non-vacuity check. |
| Consumed defaults | Attestation/Attestation.swift:546–551 | Fixed: malformed present image fields/containers must not become empty strings. Missing unpinned identity kind remains allowed. |
| Trust boundary | Attestation/Attestation.swift:463–486 | Fixed: no Security framework previously fell through without verifying signature; refuse with typed error. |
| Consumed defaults | Orchestration/ToolBuilders.swift:162 | Fixed: present non-array tools must not silently be discarded. |
| Other defaults | Endpoints/TrustedRouter+Chat.swift:202–287 | Already-safe: decoded optional stream deltas are accumulated; absent IDs/content are collector defaults, not wrong-typed raw fields. |
| Description coercion | Transport/SecureURLSession.swift:142 | Fixed mechanically: cast header name to String; no arbitrary-value ID coercions anywhere in Sources. |
| Response headers | Transport/RetryPolicy.swift:62–67 | Fixed: use value(forHTTPHeaderField:) for arbitrary case. Foundation owns repeated response fields; no SDK flattening/merging via allHeaderFields. |
| Request headers | Core/TrustedRouterClient.swift:182–324; Transport/TransportEngine.swift:260–273 | Already-safe: case-insensitive removal, lookup and layer merge; URLRequest's header API. |
| Reserved / credentials | Telemetry/ClientTelemetry.swift:59–67; Transport/CredentialScope.swift:123–126; Transport/SecureURLSession.swift:139–146 | Already-safe: names normalized or URLRequest header API; session defaults checked. |
| Repeated headers | Attestation/AttestedSession.swift:196–237 | Already-safe: lowercase names map to arrays; duplicates retained. Content-length uses last value, existing parser policy unchanged. |
| Object shape | Endpoints/TrustedRouter+Account.swift:89–92 | Fixed: non-object status JSON must throw invalidResponse, not return [:]. |
| Object shape | Endpoints/TrustedRouter+Chat.swift:171; Streaming/SSEParser.swift:166–174,264–275 | Already-safe: typed decoding / explicit object check rejects invalid shape; error presence terminates stream, never retries it. Error text fallback affects diagnostics only. |
| Error shape | Core/Errors.swift:48,82–94; Transport/RetryPolicy.swift:124–167 | Intentionally unchanged: HTTP status and retry verdict are authoritative. Malformed error JSON is diagnostic text, never a body-derived retry decision. |
| Trust shapes | Attestation/Attestation.swift:54–60,180,397–400,425,442–460,512–674 | Claims projection and secure-boot NSNumber bridging required the additional boolean fixes recorded below; other trust checks reject invalid consumed types. Image-field laundering addressed above. Missing/malformed audience, issuer, expiry, debug/hardware, nonce or cert binding cannot bypass their checks. |
| Receipt shapes | Receipts/ReceiptVerification.swift:227,343–371,429–465,506–529,732–741,861–878,990–1150 | Already-safe: strict JSON scanner, object/string/number guards and typed verification errors. Optional malformed values are rejected. |
| Receipt capture try? | Receipts/ReceiptVerification.swift:1279–1280 | Intentionally unchanged: opportunistic receipt discovery only; verify rechecks entire original wire through strict validation. A capture is not verification. |
| Best-effort JSON | Telemetry/BeaconReporter.swift:499,658–659,816,895,907; Telemetry/ClientTelemetry.swift:536–542; Transport/TransportEngine.swift:221–224 | Intentionally unchanged: telemetry sizing, policy hints and attribution; malformed input drops telemetry/hints and cannot authorize or alter HTTP retry classification. |
| Other ?? / optional casts | Options, routing, URL components, typed configuration, telemetry counters | Already-safe: typed optional configuration, aggregation and URL defaults; no wrong-typed consumed wire field is substituted. |

Static inspection cannot prove producer contracts for endpoints absent from the shared fixture. No new required pass-through fields are inferred from hand-written models.

Additional sites found during final review, recorded before their fixes:

| Class | Source site | Verdict |
|---|---|---|
| Pass-through laundering | Attestation/Attestation.swift:55–58 | Fixed: Foundation bridges JSON booleans to Double; identify CFBoolean before projecting numbers so raw claims preserve boolean semantics. |
| Consumed wrong type | Attestation/Attestation.swift, checkClaims secure-boot condition | Fixed: `as? Bool` also bridges NSNumber(1); require a real JSON boolean for secure-boot evidence. |

| Class | Source site | Verdict |
|---|---|---|
| External Data indexing | Receipts/ReceiptVerification.swift:streamDigest / findSequence | Fixed: caller-provided responseStream can be a nonzero-index Data slice. Normalize its indexing once before the scanner uses zero-based offsets. Capture-owned wire already starts at zero. |

## Verification and static gate

- `swift build` initially failed in SwiftPM's nested sandbox. `CLANG_MODULE_CACHE_PATH=/tmp/tr-swift-module-cache swift build --disable-sandbox` then passed after each implementation batch; final incremental build: **0.22 s**. This disables only SwiftPM's inner manifest sandbox, not workspace restrictions.
- `DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib swiftlint --strict --no-cache`: **0 violations in 36 source files**. The framework path is needed only for this CommandLineTools installation. CI uses ordinary `swiftlint --strict` on macos-15.
- **XCTest tests were NOT executed locally.** The XCTest target cannot run in this environment. Changed test files were reread and parsed with `swiftc -frontend -parse`; this is syntax checking, not test-target compilation or execution. macOS and swift:6.2 Linux CI remain the required runtime verification.
- Supplementary standalone executables (not the XCTest target): all **18** shared auth fixture payloads produced the expected parser acceptance/rejection, unknown exchange metadata round-tripped, sliced DER and receipt-stream Data normalized, and the renamed pure-Swift SHA implementation matched SHA-256("abc"). These checks do not replace the public-path XCTest cases or cross-repo conformance.
- Conformance command was attempted exactly with `--sdk swift --sdk-root swift=$PWD`: **sandbox-blocked**. The generated driver could not build: `sandbox-exec: sandbox_apply: Operation not permitted`. Harness summary: **25 checks, 0 passed, 25 failed, 0 skipped**; these are driver-build failures, not observed SDK behavior failures.
- `git diff --check`: passed. No commits created; no runtime dependencies added.

All default SwiftLint rules remain enabled; `force_unwrapping` and `implicitly_unwrapped_optional` are opted in, with default `force_cast` and `force_try`. No rule is globally disabled. `discouraged_optional_collection` stays off because nil and an empty collection differ in the wire contract. Tests are excluded from lint (their established mocks use force operations/IUOs); production Sources are all included.

**Project style limits differ from SwiftLint defaults:** file length 1400/1600, function length 200/240, type length 650/750, complexity 40/45, parameter count 8/10, tuple size 3/4, nesting depth 3 (warning/error pairs). These accommodate the existing sequential verification and telemetry implementations and preserve nested public API names. They avoid a large, untested structural rewrite during this boundary audit. Other existing lint findings were corrected mechanically. These configured limits are a deviation from default thresholds, not a claim that the original source met default size/complexity limits.

Four extra error rules cover direct `allHeaderFields[...]`, raw string-cast-to-empty defaults, swallowed `JSONDecoder().decode`, and object casts defaulting to `[:]`. These are syntactic checks, not a proof of producer contracts or data flow; arbitrary dictionary indexing, indirect decoder use, and whether a field is consumed still require review and fixtures.

SwiftLint 0.65.1 treats trailing reason text (including the requested em dash syntax) as extra rule names and reports `superfluous_disable_command`. Each suppression therefore has its named invariant on the immediately preceding comment line, and the directive applies only to the next line.

| Suppression | Current source site | Reason |
|---|---|---|
| `cast_string_default` | `Sources/TrustedRouter/Attestation/Attestation.swift:565` | imageContainer validated present fields; only absent, unpinned fields default. |
| `cast_string_default` | `Sources/TrustedRouter/Attestation/Attestation.swift:568` | imageContainer validated present fields; only absent, unpinned fields default. |
| `force_unwrapping` | `Sources/TrustedRouter/Endpoints/TrustedRouter+Chat.swift:239` | index comes from unchanged collected.keys. |
| `force_unwrapping` | `Sources/TrustedRouter/Endpoints/TrustedRouter+Chat.swift:244` | key comes from unchanged toolCalls.keys. |
| `identifier_name` | `Sources/TrustedRouter/Receipts/ReceiptVerification.swift:40` | public receipt API uses the wire field name of. |
| `identifier_name` | `Sources/TrustedRouter/Receipts/ReceiptVerification.swift:67` | public receipt API uses the wire field name rv. |
| `force_unwrapping` | `Sources/TrustedRouter/Streaming/ByteStream.swift:104` | iterator is initialized immediately above. |

## Mutation results

`python3 scripts/static-gate-check.py`: all eight lint mutations **KILLED**, **4.29 s** total. Each probe was actually rejected for the named rule (including the four detectable defect classes). Probes are never compiled or executed.

| Static mutation | Result |
|---|---|
| `force_unwrapping` | KILLED |
| `force_cast` | KILLED |
| `force_try` | KILLED |
| `implicitly_unwrapped_optional` | KILLED |
| `raw_response_header_lookup` | KILLED |
| `cast_string_default` | KILLED |
| `swallowed_json_decoding` | KILLED |
| `empty_object_fallback` | KILLED |

`scripts/mutation-check.sh --validate-patterns`: all 18 exact replacement patterns matched once, **0.00 s**. Runtime mutation results below are **NOT RUN locally** because XCTest is unavailable; no runtime kill is claimed. Full mutation wall time is unavailable until CI runs; the runner prints per-mutation and total wall time.

The runner requires a passing, discovered focused test before each distinct filter. A mutation counts as killed only after a successful build and an observed test failure/crash; compilation errors are infrastructure failures. Source bytes are saved before mutation, restored in Python `finally`, and restored again by a Bash EXIT/INT/TERM trap. No `git checkout` is used. A stale pattern or survivor exits nonzero. A temporary-copy infrastructure check with simulated Swift verified survivor, kill, build-failure, and stale-pattern branches plus exact-byte restoration in **0.94 s**; this is not a runtime mutation result.

| Mutation | Focused test | Runtime result |
|---|---|---|
| `exchange-data-shape` | `OAuthTests/testSharedAuthWireFixtures` | NOT RUN locally; CI gate |
| `fixture-require-unguaranteed-data` | `OAuthTests/testSharedAuthWireFixtures` | NOT RUN locally; CI gate |
| `legacy-null-sub` | `OAuthTests/testSharedAuthWireFixtures` | NOT RUN locally; CI gate |
| `unknown-fields-pass-through` | `OAuthTests/testSharedAuthWireFixtures` | NOT RUN locally; CI gate |
| `unknown-affiliation-pass-through` | `OAuthTests/testUnknownAffiliationFieldsPassThrough` | NOT RUN locally; CI gate |
| `der-data-indices` | `DERTests/testIntegerNormalizesMultipleZerosAndSlicedData` | NOT RUN locally; CI gate |
| `case-insensitive-headers` | `HeaderMergeTests/testResponseHeadersAcceptArbitraryCasing` | NOT RUN locally; CI gate |
| `status-object-shape` | `TrustedRouterEndpointTests/testStatusRejectsNonObjectJSON` | NOT RUN locally; CI gate |
| `fusion-tools-shape` | `FusionTests/testFusionRejectsMalformedToolsBeforeSending` | NOT RUN locally; CI gate |
| `trust-release-field-validation` | `AttestationPolicyPropertyTests/testMalformedPublishedPinsCannotHideBehindAValidPin` | NOT RUN locally; CI gate |
| `claim-image-field-validation` | `AttestationPolicyPropertyTests/testMalformedClaimImageFieldsAreRejected` | NOT RUN locally; CI gate |
| `claim-submods-shape` | `AttestationPolicyPropertyTests/testMalformedClaimImageFieldsAreRejected` | NOT RUN locally; CI gate |
| `claim-container-shape` | `AttestationPolicyPropertyTests/testMalformedClaimImageFieldsAreRejected` | NOT RUN locally; CI gate |
| `claim-validator-hookup` | `AttestationPolicyPropertyTests/testMalformedClaimImageFieldsAreRejected` | NOT RUN locally; CI gate |
| `unsupported-rs256-fails-closed` | `AttestationPolicyPropertyTests/testUnsupportedSignatureVerificationFailsClosed` | NOT RUN locally; CI gate |
| `raw-claim-boolean` | `AttestationPolicyPropertyTests/testJSONBooleanClaimsKeepTheirType` | NOT RUN locally; CI gate |
| `secure-boot-boolean` | `AttestationPolicyPropertyTests/testNumericSecureBootIsRejected` | NOT RUN locally; CI gate |
| `receipt-stream-data-indices` | `ReceiptVerificationTests/testStreamVerificationAcceptsNonzeroDataIndices` | NOT RUN locally; CI gate |

The invariant-backed force-operation removals are behavior-preserving cleanup, not new guards requiring a behavioral mutant. Their regression gate is lint. `testUnsignedJWTIsRejectedOnEveryPlatform` also checks the actual unsupported-platform verifier path in Linux CI; the macOS mutation gate exercises the shared typed-refusal helper.

## Shared fixture

`Tests/TrustedRouterTests/Fixtures/auth-wire-fixtures.json` is copied **byte-for-byte** from the supplied shared file.

SHA-256: `ba492afe81f7616bca062ab7ed35f70d42042e6f6f60794ac9e2a599574df1d2`.

It is loaded through SwiftPM `.copy` resources and `Bundle.module`, matching the package's existing receipt-resource pattern and supported on both macOS and Linux. The test uses the real public `exchangeOAuthKey` / `fetchUserInfo` transport and parsing paths with URLProtocol, asserts consumed fields, recursively checks retained metadata, and requires DecodingError for all reject cases.

Public model correction: `UserInfo.sub` is now `String?` (including its initializer), because production ownerless keys return null. OAuthIdentity.sub remains a required string. OAuthToken.data is optional object metadata; minimal `{key, user_id}` remains valid. OAuth models expose `additionalFields` and preserve unknown JSON through decoding/encoding. Company affiliations remain optional; unknown affiliation metadata also survives. Other public names and argument labels are unchanged.

## Current change locations

Every edited/new file is listed below; source style-only edits include descriptive local names, whitespace, statement layout, line wrapping, and removing redundant nil initializers. The semantic changes and test filters are detailed above.

| File:line | Change |
|---|---|
| `.github/workflows/ci.yml:15` | macOS lint before tests; static and runtime mutation gates; Linux swift test retained. |
| `.swiftlint.yml:1` | Default rule set plus force rules and four boundary patterns; explicit style limits. |
| `Package.swift:29` | Bundle resource for the byte-identical shared fixture. |
| `Sources/TrustedRouter/Attestation/Attestation.swift:21` | Trust image validation, real boolean evidence, raw boolean preservation, unsupported signature refusal; UTF-8 force removal and lint cleanup. |
| `Sources/TrustedRouter/Attestation/AttestedSession.swift:43` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Attestation/DER.swift:19` | Normalize external byte indices using an Array; public RSA labels preserved. |
| `Sources/TrustedRouter/Attestation/ImageBoundary.swift:1` | Typed trust-field and JSON boolean helpers; unsupported-platform refusal. |
| `Sources/TrustedRouter/Core/Errors.swift:80` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Core/Options.swift:134` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Core/TrustedRouterClient.swift:83` | Conditional generic Data cast, total UTF-8 conversion, local names and formatting. |
| `Sources/TrustedRouter/Endpoints/TrustedRouter+Account.swift:89` | Reject non-object status responses with invalidResponse. |
| `Sources/TrustedRouter/Endpoints/TrustedRouter+Broadcast.swift:52` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Endpoints/TrustedRouter+Chat.swift:238` | Name the two dictionary-key force-unwrap invariants. |
| `Sources/TrustedRouter/Models/Models.swift:24` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/OAuth/CompanyAffiliation+Codable.swift:1` | Strict known-field decoding with unknown-field pass-through encoding. |
| `Sources/TrustedRouter/OAuth/OAuth.swift:80` | Move models into OAuthModels.swift; descriptive SHA locals and formatting. |
| `Sources/TrustedRouter/OAuth/OAuthFields.swift:1` | Preserve unknown wire fields without schema requirements. |
| `Sources/TrustedRouter/OAuth/OAuthIdentity+Codable.swift:1` | Strict known-field decoding with unknown-field pass-through encoding. |
| `Sources/TrustedRouter/OAuth/OAuthLoopback.swift:285` | Optional buffer base address and descriptive local names; request-line UTF-8 replacement behavior preserved. |
| `Sources/TrustedRouter/OAuth/OAuthModels.swift:1` | Nullable UserInfo subject, optional token metadata, unknown-field storage; existing model API retained otherwise. |
| `Sources/TrustedRouter/OAuth/OAuthToken+Codable.swift:1` | Strict known-field decoding with unknown-field pass-through encoding. |
| `Sources/TrustedRouter/OAuth/UserInfo+Codable.swift:1` | Strict known-field decoding with unknown-field pass-through encoding. |
| `Sources/TrustedRouter/OAuth/UserInfoResponse+Codable.swift:1` | Strict known-field decoding with unknown-field pass-through encoding. |
| `Sources/TrustedRouter/Orchestration/ToolBuilders.swift:162` | Reject malformed caller-supplied tools before transport. |
| `Sources/TrustedRouter/Receipts/ReceiptVerification.swift:39` | Normalize external SSE Data slices; remove short-circuit-backed unwraps; preserve public wire names with documented exceptions. |
| `Sources/TrustedRouter/Streaming/ByteStream.swift:35` | Name the initialized-iterator invariant; nil style cleanup. |
| `Sources/TrustedRouter/Streaming/SSEParser.swift:96` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Telemetry/BeaconReporter.swift:100` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Telemetry/ClientTelemetry.swift:161` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Sources/TrustedRouter/Transport/RetryPolicy.swift:63` | Use Foundation case-insensitive response-header lookup. |
| `Sources/TrustedRouter/Transport/SecureURLSession.swift:73` | Use the already-copying configuration getter; String-only header names. |
| `Sources/TrustedRouter/Transport/TransportEngine.swift:205` | Mechanical default-rule lint cleanup; behavior unchanged. |
| `Tests/TrustedRouterTests/AttestationPolicyPropertyTests.swift:1` | Focused boundary tests; existing helpers and platform guards retained. |
| `Tests/TrustedRouterTests/DERTests.swift:1` | Focused boundary tests; existing helpers and platform guards retained. |
| `Tests/TrustedRouterTests/Fixtures/auth-wire-fixtures.json:1` | Verbatim shared producer fixture. |
| `Tests/TrustedRouterTests/FusionTests.swift:85` | Focused boundary tests; existing helpers and platform guards retained. |
| `Tests/TrustedRouterTests/HeaderMergeTests.swift:1` | Focused boundary tests; existing helpers and platform guards retained. |
| `Tests/TrustedRouterTests/OAuthTests.swift:290` | Focused boundary tests; existing helpers and platform guards retained. |
| `Tests/TrustedRouterTests/ReceiptVerificationTests.swift:633` | Focused boundary tests; existing helpers and platform guards retained. |
| `Tests/TrustedRouterTests/TrustedRouterEndpointTests.swift:312` | Focused boundary tests; existing helpers and platform guards retained. |
| `docs/boundary-audit.md:1` | Pre-edit site inventory and final evidence, limitations, suppressions and outcomes. |
| `scripts/mutation-check.py:1` | Stale/survivor/build-failure detection, exact-byte finally restoration and timings. |
| `scripts/mutation-check.sh:1` | Bash snapshot-restoration trap and Python runner entry point. |
| `scripts/mutations.json:1` | 18 exact source mutations and focused test filters. |
| `scripts/static-gate-check.py:1` | Eight executable lint rejection proofs with probe cleanup. |

Current behavioral anchors (all under `Sources/TrustedRouter`):

| Change | Current file:line |
|---|---|
| Preserve JSON boolean claims / reject numeric secure boot | `Attestation/Attestation.swift:55`, `Attestation/Attestation.swift:545`, `Attestation/ImageBoundary.swift:37` |
| Validate published image pins / consumed claim image fields | `Attestation/Attestation.swift:215`, `Attestation/Attestation.swift:563`, `Attestation/ImageBoundary.swift:8`, `Attestation/ImageBoundary.swift:23` |
| Fail closed without signature verification | `Attestation/Attestation.swift:500`, `Attestation/ImageBoundary.swift:4` |
| Normalize DER and receipt stream Data indices | `Attestation/DER.swift:19`, `Receipts/ReceiptVerification.swift:753` |
| Header casing / status object / malformed tools | `Transport/RetryPolicy.swift:63`, `Endpoints/TrustedRouter+Account.swift:89`, `Orchestration/ToolBuilders.swift:162` |
| Remove safe force operations | `Attestation/Attestation.swift:415`, `Core/TrustedRouterClient.swift:468`, `OAuth/OAuthLoopback.swift:355`, `Transport/SecureURLSession.swift:73`, `Transport/SecureURLSession.swift:138`, `Receipts/ReceiptVerification.swift:664`, `Receipts/ReceiptVerification.swift:1072` |
| Correct auth wire decoding and preserve fields | `OAuth/OAuthToken+Codable.swift:4`, `OAuth/UserInfo+Codable.swift:4`, `OAuth/OAuthIdentity+Codable.swift:4`, `OAuth/CompanyAffiliation+Codable.swift:4`, `OAuth/UserInfoResponse+Codable.swift:4`, `OAuth/OAuthFields.swift:3` |

Focused test anchors (under `Tests/TrustedRouterTests`): `OAuthTests.swift:302,368`; `DERTests.swift:110`; `HeaderMergeTests.swift:252`; `FusionTests.swift:87`; `TrustedRouterEndpointTests.swift:314`; `ReceiptVerificationTests.swift:633`; `AttestationPolicyPropertyTests.swift:168,186,222,230,239,261`.
