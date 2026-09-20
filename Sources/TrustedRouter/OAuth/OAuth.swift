import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Security)
import Security
#endif

#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// MARK: - PKCE

/// A PKCE (Proof Key for Code Exchange, RFC 7636) verifier/challenge pair.
///
/// Mirrors the JS SDK's `createOAuthPkcePair`: the verifier is
/// `base64url(32 random bytes)` and the challenge is
/// `base64url(SHA256(verifier))` with method `"S256"`.
public struct PKCEChallenge: Sendable, Equatable {
    /// The high-entropy `code_verifier` kept by the client and sent to
    /// `/auth/keys` during exchange. Never put this in the authorize URL.
    public let codeVerifier: String
    /// The `code_challenge` derived from the verifier (S256). Safe to put
    /// in the authorize URL.
    public let codeChallenge: String
    /// Always `"S256"` for the challenges this type produces.
    public let codeChallengeMethod: String

    /// Creates a `PKCEChallenge` with the supplied values.
    public init(codeVerifier: String, codeChallenge: String, codeChallengeMethod: String = "S256") {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
    }

    /// Generate a fresh S256 PKCE pair. The verifier is 32 random bytes,
    /// base64url-encoded; the challenge is the base64url SHA-256 of the
    /// verifier's ASCII bytes (no padding), matching the JS SDK.
    ///
    /// - Parameter codeVerifier: Optional pre-chosen verifier (mainly for
    ///   tests / determinism). When `nil`, a cryptographically random one is
    ///   generated.
    public static func generate(codeVerifier: String? = nil) -> PKCEChallenge {
        let verifier = codeVerifier ?? OAuthCrypto.randomBase64URL(byteLength: 32)
        let challenge = OAuthCrypto.sha256Base64URL(verifier)
        return PKCEChallenge(codeVerifier: verifier, codeChallenge: challenge, codeChallengeMethod: "S256")
    }
}

/// Generate a random opaque `state` value (16 random bytes, base64url) used
/// to bind the authorize redirect to this client and defeat CSRF. Mirrors the
/// JS SDK's `randomOAuthState`.
public func randomOAuthState(byteLength: Int = 16) -> String {
    OAuthCrypto.randomBase64URL(byteLength: byteLength)
}

// MARK: - Crypto helpers (portable: Apple + Linux)

/// Internal crypto primitives shared by PKCE/state generation. Uses
/// `SecRandomCopyBytes` where available (Apple platforms) and a secure
/// system RNG fallback on Linux, plus CryptoKit/swift-crypto SHA-256.
enum OAuthCrypto {
    /// Fill `count` bytes with cryptographically-secure randomness.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return bytes
        }
        // Fall through to the system RNG if Security ever fails.
        #endif
        var rng = SystemRandomNumberGenerator()
        for index in 0..<count {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
        }
        return bytes
    }

    /// `byteLength` random bytes, base64url-encoded with padding stripped.
    static func randomBase64URL(byteLength: Int) -> String {
        base64URLEncode(Data(randomBytes(byteLength)))
    }

    /// base64url(SHA256(utf8(text))) with padding stripped — the S256
    /// transform applied to a PKCE verifier.
    static func sha256Base64URL(_ text: String) -> String {
        base64URLEncode(Data(sha256(Array(text.utf8))))
    }

    /// SHA-256 of `message`. Uses CryptoKit on Apple platforms; falls back to
    /// a small pure-Swift implementation on Linux (the package carries zero
    /// dependencies, so swift-crypto isn't available there).
    static func sha256(_ message: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: Data(message)))
        #else
        return SHA256Pure.digest(message)
        #endif
    }

    /// Standard base64 → base64url: `+`→`-`, `/`→`_`, strip trailing `=`.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if !canImport(CryptoKit)
/// Minimal, dependency-free SHA-256 (FIPS 180-4). Only compiled on platforms
/// without CryptoKit (i.e. Linux) so the SDK can keep its zero-dependency
/// promise while still computing PKCE S256 challenges everywhere.
enum SHA256Pure {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var hashState: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]

        // Pre-processing (padding).
        var msg = message
        let bitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0x00) }
        for index in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLength >> UInt64(index)) & 0xff))
        }

        func rotr(_ value: UInt32, _ shift: UInt32) -> UInt32 { (value >> shift) | (value << (32 - shift)) }

        // Process each 512-bit chunk.
        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                schedule[index] = (UInt32(msg[offset]) << 24) | (UInt32(msg[offset + 1]) << 16)
                     | (UInt32(msg[offset + 2]) << 8) | UInt32(msg[offset + 3])
            }
            for index in 16..<64 {
                let sigma0 = rotr(schedule[index - 15], 7)
                    ^ rotr(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let sigma1 = rotr(schedule[index - 2], 17) ^ rotr(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
            }

            var stateA = hashState[0], stateB = hashState[1], stateC = hashState[2], stateD = hashState[3]
            var stateE = hashState[4], stateF = hashState[5], stateG = hashState[6], stateH = hashState[7]

            for index in 0..<64 {
                let sigma1 = rotr(stateE, 6) ^ rotr(stateE, 11) ^ rotr(stateE, 25)
                let choice = (stateE & stateF) ^ (~stateE & stateG)
                let temp1 = stateH &+ sigma1 &+ choice &+ roundConstants[index] &+ schedule[index]
                let sigma0 = rotr(stateA, 2) ^ rotr(stateA, 13) ^ rotr(stateA, 22)
                let maj = (stateA & stateB) ^ (stateA & stateC) ^ (stateB & stateC)
                let temp2 = sigma0 &+ maj
                stateH = stateG; stateG = stateF; stateF = stateE; stateE = stateD &+ temp1
                stateD = stateC; stateC = stateB; stateB = stateA; stateA = temp1 &+ temp2
            }

            hashState[0] = hashState[0] &+ stateA
            hashState[1] = hashState[1] &+ stateB
            hashState[2] = hashState[2] &+ stateC
            hashState[3] = hashState[3] &+ stateD
            hashState[4] = hashState[4] &+ stateE
            hashState[5] = hashState[5] &+ stateF
            hashState[6] = hashState[6] &+ stateG
            hashState[7] = hashState[7] &+ stateH
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for value in hashState {
            out.append(UInt8((value >> 24) & 0xff))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(value & 0xff))
        }
        return out
    }
}
#endif

// MARK: - Authorize URL

/// Build the browser-redirect authorize URL for the TrustedRouter OAuth flow.
///
/// Matches the JS SDK's `oauthAuthorizeUrl` exactly: TrustedRouter uses
/// `callback_url` (NOT `redirect_uri`), there is no `client_id`/`response_type`/
/// `scope`, and the `state` is *embedded into* `callback_url` rather than sent
/// as its own top-level param. Only parameters that are set are included.
///
/// - Parameters:
///   - baseURL: control/website base, defaulting to the SDK control default.
///     Trailing slashes are trimmed before joining `"/auth"`.
///   - callbackURL: REQUIRED redirect target. After approval the backend
///     redirects to `callbackURL?code=...&user_id=...` (plus the embedded
///     `state`).
///   - codeChallenge: PKCE S256 challenge.
///   - codeChallengeMethod: defaults to `"S256"` when a challenge is supplied.
///   - state: opaque CSRF token; embedded into `callback_url` when present.
/// - Throws: `TrustedRouterError.internalError` if `callbackURL` is missing/
///   invalid, or if a method is given without a challenge.
public func oauthAuthorizeURL(
    baseURL: String = TrustedRouterConstants.defaultControlBaseURL,
    callbackURL: String,
    codeChallenge: String? = nil,
    codeChallengeMethod: String? = nil,
    keyLabel: String? = nil,
    limit: String? = nil,
    usageLimitType: String? = nil,
    expiresAt: String? = nil,
    spawnAgent: String? = nil,
    spawnCloud: String? = nil,
    state: String? = nil
) throws -> URL {
    if callbackURL.isEmpty {
        throw TrustedRouterError.internalError("callbackURL is required")
    }
    let method = codeChallengeMethod ?? (codeChallenge != nil ? "S256" : nil)
    if method != nil && codeChallenge == nil {
        throw TrustedRouterError.internalError("codeChallenge is required when codeChallengeMethod is set")
    }

    // Trim trailing slashes off the base, the same way the client does.
    var trimmedBase = baseURL
    while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }

    guard var components = URLComponents(string: "\(trimmedBase)/auth") else {
        throw TrustedRouterError.internalError("invalid baseURL: \(baseURL)")
    }

    // Embed state into the callback URL (matches JS `callbackUrlWithState`).
    let effectiveCallback = try state.map { try embedState($0, into: callbackURL) } ?? callbackURL

    var items: [URLQueryItem] = [URLQueryItem(name: "callback_url", value: effectiveCallback)]
    if let codeChallenge { items.append(URLQueryItem(name: "code_challenge", value: codeChallenge)) }
    if let method { items.append(URLQueryItem(name: "code_challenge_method", value: method)) }
    if let keyLabel { items.append(URLQueryItem(name: "key_label", value: keyLabel)) }
    if let limit { items.append(URLQueryItem(name: "limit", value: limit)) }
    if let usageLimitType { items.append(URLQueryItem(name: "usage_limit_type", value: usageLimitType)) }
    if let expiresAt { items.append(URLQueryItem(name: "expires_at", value: expiresAt)) }
    if let spawnAgent { items.append(URLQueryItem(name: "spawn_agent", value: spawnAgent)) }
    if let spawnCloud { items.append(URLQueryItem(name: "spawn_cloud", value: spawnCloud)) }

    components.queryItems = items
    guard let url = components.url else {
        throw TrustedRouterError.internalError("could not build authorize URL")
    }
    return url
}

/// Set/replace the `state` query param on `callbackURL`, mirroring the JS
/// `callbackUrlWithState`.
private func embedState(_ state: String, into callbackURL: String) throws -> String {
    guard var components = URLComponents(string: callbackURL) else {
        throw TrustedRouterError.internalError("invalid callbackURL: \(callbackURL)")
    }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "state" }
    items.append(URLQueryItem(name: "state", value: state))
    components.queryItems = items
    guard let result = components.url?.absoluteString else {
        throw TrustedRouterError.internalError("could not embed state into callbackURL")
    }
    return result
}

// MARK: - Exchange + userinfo (build on ALL platforms, incl. Linux)

/// Exchange an authorization `code` (plus the PKCE `code_verifier` kept from
/// the authorize step) for a delegated key.
///
/// `POST {baseURL}/auth/keys` with body `{code, code_verifier?, code_challenge_method?}`
/// and **no** Authorization header (public client). Mirrors the JS SDK's
/// `exchangeOAuthKey`.
public func exchangeOAuthKey(
    code: String,
    codeVerifier: String? = nil,
    codeChallengeMethod: String? = nil,
    baseURL: String = TrustedRouterConstants.defaultControlBaseURL,
    urlSession: URLSession = .shared
) async throws -> OAuthToken {
    if code.isEmpty {
        throw TrustedRouterError.internalError("code is required")
    }
    // Public-client exchange: an empty apiKey suppresses the Authorization
    // header in the client's header builder.
    let client = try TrustedRouter(options: .init(
        apiKey: "",
        controlBaseURL: baseURL,
        urlSession: urlSession.trustedRouterCredentialFreeCopy()
    ))
    var body: [String: Any] = ["code": code]
    if let codeVerifier { body["code_verifier"] = codeVerifier }
    if let codeChallengeMethod { body["code_challenge_method"] = codeChallengeMethod }
    return try await client.request(method: "POST", path: "/auth/keys", body: body, plane: .control)
}

/// Fetch the verified identity for `apiKey` (a delegated key).
///
/// `GET {baseURL}/auth/userinfo` with `Authorization: Bearer <apiKey>`.
/// Returns the inner `data` payload. Mirrors the JS SDK's `userInfo`.
public func fetchUserInfo(
    apiKey: String,
    baseURL: String = TrustedRouterConstants.defaultControlBaseURL,
    urlSession: URLSession = .shared
) async throws -> UserInfo {
    if apiKey.isEmpty {
        throw TrustedRouterError.internalError("apiKey is required")
    }
    let client = try TrustedRouter(options: .init(apiKey: apiKey, controlBaseURL: baseURL, urlSession: urlSession))
    let envelope: UserInfoResponse = try await client.request(method: "GET", path: "/auth/userinfo", plane: .control)
    return envelope.data
}

// MARK: - High-level interactive helper (Apple platforms only)

#if canImport(AuthenticationServices)

/// High-level browser OAuth helper built on `ASWebAuthenticationSession`.
///
/// This is what Lore (macOS/iOS) uses: it generates PKCE, opens the authorize
/// URL in a system browser sheet, captures the redirect to your custom scheme,
/// validates `state`, and exchanges the `code` for an `OAuthToken`.
///
/// Linux builds (QuillUI cross-platform) get the pure PKCE/exchange/userinfo
/// functions above; this interactive helper is compiled only where
/// `AuthenticationServices` exists.
@available(macOS 10.15, iOS 13.0, tvOS 16.0, *)
@MainActor
public final class TrustedRouterOAuth {
    /// Base URL used for OAuth requests.
    public let baseURL: String
    /// Session whose configuration supplies the request transport policy.
    public let urlSession: URLSession

    /// Optional defaults forwarded into the authorize URL.
    public var keyLabel: String?
    /// Spending limit requested for the delegated key.
    public var limit: String?
    /// Accounting interval used for the delegated key limit.
    public var usageLimitType: String?
    /// Expiration time for the token or delegated credential.
    public var expiresAt: String?
    /// Whether the authorization flow requests an agent.
    public var spawnAgent: String?
    /// Whether the authorization flow requests a cloud instance.
    public var spawnCloud: String?

    /// Creates a `TrustedRouterOAuth` with the supplied values.
    public init(
        baseURL: String = TrustedRouterConstants.defaultControlBaseURL,
        urlSession: URLSession = .shared,
        keyLabel: String? = nil,
        limit: String? = nil,
        usageLimitType: String? = nil,
        expiresAt: String? = nil,
        spawnAgent: String? = nil,
        spawnCloud: String? = nil
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.keyLabel = keyLabel
        self.limit = limit
        self.usageLimitType = usageLimitType
        self.expiresAt = expiresAt
        self.spawnAgent = spawnAgent
        self.spawnCloud = spawnCloud
    }

    /// Run the full interactive OAuth flow and return the delegated key +
    /// identity.
    ///
    /// - Parameters:
    ///   - callbackURL: Your redirect target, e.g. `"lore://oauth-callback"`.
    ///     The custom scheme is extracted and handed to
    ///     `ASWebAuthenticationSession` as the `callbackURLScheme`.
    ///   - presentationContextProvider: Anchors the auth sheet to a window
    ///     (required on macOS / iPad). The SDK keeps only a weak reference.
    ///   - prefersEphemeralWebBrowserSession: When `true`, the session does
    ///     not share cookies with Safari (forces a fresh login).
    public func authenticate(
        callbackURL: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding? = nil,
        prefersEphemeralWebBrowserSession: Bool = false
    ) async throws -> OAuthToken {
        let pkce = PKCEChallenge.generate()
        let state = randomOAuthState()

        let authorizeURL = try oauthAuthorizeURL(
            baseURL: baseURL,
            callbackURL: callbackURL,
            codeChallenge: pkce.codeChallenge,
            codeChallengeMethod: pkce.codeChallengeMethod,
            keyLabel: keyLabel,
            limit: limit,
            usageLimitType: usageLimitType,
            expiresAt: expiresAt,
            spawnAgent: spawnAgent,
            spawnCloud: spawnCloud,
            state: state
        )

        guard let scheme = URL(string: callbackURL)?.scheme else {
            throw TrustedRouterError.internalError("callbackURL must include a scheme: \(callbackURL)")
        }

        let redirectURL = try await presentSession(
            authorizeURL: authorizeURL,
            callbackScheme: scheme,
            presentationContextProvider: presentationContextProvider,
            prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
        )

        let (code, returnedState) = try Self.parseCallback(redirectURL)
        guard returnedState == state else {
            throw TrustedRouterError.internalError("OAuth state mismatch (possible CSRF); aborting exchange")
        }

        return try await exchangeOAuthKey(
            code: code,
            codeVerifier: pkce.codeVerifier,
            codeChallengeMethod: pkce.codeChallengeMethod,
            baseURL: baseURL,
            urlSession: urlSession
        )
    }

    /// Convenience: authenticate, then fetch userinfo with the new key.
    public func authenticateAndFetchUserInfo(
        callbackURL: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding? = nil,
        prefersEphemeralWebBrowserSession: Bool = false
    ) async throws -> (token: OAuthToken, userInfo: UserInfo) {
        let token = try await authenticate(
            callbackURL: callbackURL,
            presentationContextProvider: presentationContextProvider,
            prefersEphemeralWebBrowserSession: prefersEphemeralWebBrowserSession
        )
        let info = try await fetchUserInfo(apiKey: token.key, baseURL: baseURL, urlSession: urlSession)
        return (token, info)
    }

    /// Parse the redirect URL the backend sent us, pulling out `code` (and the
    /// echoed `state`). Internal visibility so tests can exercise it without a
    /// live browser; `nonisolated` because it touches no actor state.
    nonisolated static func parseCallback(_ url: URL) throws -> (code: String, state: String?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TrustedRouterError.internalError("invalid OAuth callback URL")
        }
        let items = components.queryItems ?? []
        if let errorItem = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value
            throw TrustedRouterError.internalError("OAuth error: \(errorItem)\(desc.map { " — \($0)" } ?? "")")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw TrustedRouterError.internalError("OAuth callback missing 'code'")
        }
        let state = items.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    private func presentSession(
        authorizeURL: URL,
        callbackScheme: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding?,
        prefersEphemeralWebBrowserSession: Bool
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(
                        throwing: TrustedRouterError.internalError(
                            "OAuth session failed: \(error.localizedDescription)"
                        )
                    )
                    return
                }
                guard let callbackURL else {
                    continuation.resume(
                        throwing: TrustedRouterError.internalError("OAuth session returned no callback URL")
                    )
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
            if !session.start() {
                continuation.resume(
                    throwing: TrustedRouterError.internalError("could not start ASWebAuthenticationSession")
                )
            }
        }
    }
}

#endif
