# trusted-router-swift

Swift SDK for [TrustedRouter](https://trustedrouter.com).

This is a pure Swift, zero-dependency client SDK for the TrustedRouter gateway. It provides the same interface, error handling, SSE streaming, and GCP Confidential Space JWT verification as the Python and Javascript SDKs.

## Installation

Add this to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/Lore-Hex/trusted-router-swift.git", from: "0.7.0")
```

Then add `"TrustedRouter"` to your target's dependencies.

## Usage

```swift
import TrustedRouter

let client = try TrustedRouter(options: .init(apiKey: "your-api-key"))

// Typed catalog calls
let models = try await client.models()                    // DataList<ModelInfo>
print(models.data.map(\.id))

// Typed chat with the ChatMessage convenience constructors
let answer = try await client.chatCompletions(messages: [
    .system("Reply with one word."),
    .user("Hello?"),
])
print(answer.choices.first?.message.content ?? "")

// SSE streaming, typed chunks
let stream = try await client.chatCompletionsChunks(messages: [
    .user("Tell me a joke."),
])
for try await chunk in stream {
    if let delta = chunk.choices.first?.delta?.content {
        print(delta, terminator: "")
    }
}
```

By default, inference routes use `https://api.trustedrouter.com/v1`.
Metadata, account, OAuth, billing, activity, provider, region, credit, and
broadcast-destination routes use the control plane at
`https://trustedrouter.com/v1`. Override inference routing with `baseUrl`, and
override control routing with `controlBaseURL`. On its first inference request,
the default client probes the published US Central, US East, and Europe
gateways in parallel, pins the lowest-latency healthy region, and preserves the
same idempotency key when failing over to another region. Reuse one client to
retain region affinity and `URLSession` pooling, reuse DNS results, and improve
prompt-cache locality. Set `regionalAffinity: false` to keep using only the global apex. A
custom `baseUrl` is never probed or rewritten; a custom `URLSession` defaults
affinity off unless `regionalAffinity: true` is explicit.

### Client reliability telemetry

For known TrustedRouter inference and control hosts, content-free reliability
telemetry defaults on. Each inference attempt carries the bounded
`x-tr-client` header, and a background reporter sends sampled request outcomes
plus exact per-minute counters to the control plane. The reporter has its own
single-shot `URLSession`; it never uses an injected session or the inference
retry/failover engine. Set `telemetrySampleRate` to tune otherwise healthy
single-attempt sampling (failures, retries/failover, and calls over 30 seconds
remain at 100%). Call `close()` or `shutdown()` for a final flush bounded to two
seconds. From an async task, prefer `await shutdown()` so the cooperative
executor thread is not occupied by the synchronous bounded wait.

Set `telemetry: false`, `TRUSTEDROUTER_TELEMETRY=0`, or `DO_NOT_TRACK=1` to
disable both channels. `TRUSTEDROUTER_TELEMETRY_DEBUG=1` echoes each
content-free batch JSON to stderr before delivery.

### Fusion

Fan a request across a panel of models and let a judge model pick or synthesize
one answer. `fusion(...)` returns the same `ChatCompletion` as `chatCompletions`.
`fusionFreedomPanel` / `fusionFreedomFallbackJudges` are the recommended
most-permissive configuration.

```swift
let answer = try await client.fusion(
    messages: [.user("explain how mRNA vaccines work")],
    analysisModels: TrustedRouterConstants.fusionFreedomPanel,   // the panel
    judgeModel: "z-ai/glm-5.1",                                  // judge / synthesis model
    selectionStrategy: "first_non_refusal",                      // or synthesize / synthesize_non_refusals / first_success
    fallbackJudges: TrustedRouterConstants.fusionFreedomFallbackJudges  // tried in order if a judge refuses/fails
)
print(answer.choices.first?.message.content ?? "")
```

Or build the spec with `TrustedRouter.fusionTool(...)` and attach it to any chat
call. `preset: "quality"` or `"budget"` selects a built-in panel.

### Privacy and orchestration primitives

Use `ProviderPreferences` when privacy or US provider jurisdiction must be a
hard requirement, including with an explicit model. Use
`TrustedRouterConstants.euModel` for the EU-focused routing pool:

```swift
let response = try await client.chatCompletions(
    model: "z-ai/glm-5.2",
    messages: [.user("Review this contract.")],
    provider: .confidential
)
```

Stable constants cover ZDR, E2E/confidential, EU, US, Socrates, Prometheus,
Zeus, and Athena. Custom orchestration uses the same five atomic builders as
the other SDKs: `fusionTool`, `advisorTool`, `selectorTool`, `mapReduceTool`,
and `subagentTool`.

## Features

- **Asynchronous**: Built fully on modern Swift Concurrency (`async/await`, `Task`).
- **Streaming**: Pull-based SSE parsing with a 1 MiB frame cap. Apple platforms
  use live `URLSession.AsyncBytes` with end-to-end backpressure. On Linux,
  `FoundationNetworking` first buffers the complete HTTP response with
  `data(for:)`; the SDK then replays those bytes on demand without a second
  eager queue. Linux therefore preserves parser bounds and API compatibility,
  but does **not** provide bounded-memory live network streaming.
- **Attestation Verification**: Verifies the Confidential Space JWT using `CryptoKit`/`Security`.
- **Pure Swift**: No 3rd party dependencies. Operates seamlessly on macOS, iOS, tvOS, watchOS, and Linux with `FoundationNetworking`.
- **Retries**: Implements transparent exponential backoff on `429` responses and regional failover for `502`/`503`/`504` or transport errors.
- **Transport isolation**: An injected `URLSession` contributes its
  configuration (protocol handlers, proxy/cache/timeout/header/cookie policy),
  but SDK sends use a private clone without its delegate or credential store.
  This prevents ambient HTTP-auth follow-ups; TLS server trust still uses
  Foundation's default handling. Delegate-based private-CA trust, certificate
  pinning, mTLS/client-certificate selection, and authentication customization
  are therefore intentionally not inherited by SDK requests.

## Domain failover

The regional gateways all live under one name on one DNS provider, and the
domain sits above every cloud behind it. A zone that stops answering, a
registrar lock, or a resolver handing out a stale record takes the API down no
matter how many regions are healthy.

`TrustedRouterConstants.aliasAPIBaseURLs` — `api.allyrouter.com` and
`api.uptimerouter.com` — are exact aliases of the primary, on separate domains
served by separate DNS providers, resolving to the same attested enclaves. They
sit at the end of the candidate list, after the regional gateways, so a healthy
deployment never touches them. They are deliberately left out of the health
race: they resolve to the same enclaves, so racing them would move healthy
traffic off the primary on a coin flip. Nothing to configure; it is on by
default, including when you inject your own `URLSession`.

Failover changes host only on connection failures and on `502`, `503`, or
`504`. A `500` means a server received and processed the request. You are not
charged twice for it — authorization is idempotent per `Idempotency-Key` and
settlement happens once — but the work would run a second time, so the answer
could differ and TrustedRouter pays the provider again. A 500 is retried on the
same host.

Aliases are used only for the default `baseUrl`. A custom one — a private
deployment, a test server, a regional pin — is never rewritten. Pass
`regionalFailover: false` to keep every attempt on a single host.

## Sign in with TrustedRouter

Let users "bring their own TrustedRouter account" via the OAuth **PKCE** flow,
which mints a user-scoped key so LLM calls are billed to *that user's* credits.
On iOS/macOS, `TrustedRouterOAuth().authenticate(...)` runs the whole flow in an
`ASWebAuthenticationSession`: it generates PKCE + `state`, opens the system
browser, validates the redirect, and returns the delegated key + identity.

```swift
import TrustedRouter

let oauth = TrustedRouterOAuth(keyLabel: "My App", limit: "5")
let token = try await oauth.authenticate(
    callbackURL: "myapp://oauth-callback",          // your registered custom scheme
    presentationContextProvider: self)              // anchors the auth sheet
let key = token.key                                 // sk-tr-v1-… ; token.identity = {sub, email, …}

let who = try await fetchUserInfo(apiKey: key)      // verified identity
```

`AuthenticationServices` isn't available on Linux, so for cross-platform GUI
apps (e.g. Lore games on QuillUI) compose the pure pieces that build on every
platform: generate `PKCEChallenge.generate()` + `randomOAuthState()`, open
`oauthAuthorizeURL(callbackURL:codeChallenge:state:…)` in the system browser
(use a loopback `callback_url` like `http://localhost:3000/callback`), then call
`exchangeOAuthKey(code:codeVerifier:)` and `fetchUserInfo(apiKey:)`.

Full flow, endpoints, and security notes:
[Sign in with TrustedRouter](https://github.com/Lore-Hex/quill-router/blob/main/docs/sign-in-with-trustedrouter.md).

## License

Apache 2.0
