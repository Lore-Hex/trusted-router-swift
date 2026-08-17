import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L4 — CREDENTIAL SCOPE. Decides whether a resolved request URL may carry
// the SDK-attached credential headers (`authorization`,
// `x-trustedrouter-workspace`, `idempotency-key`). Relative paths always
// resolve against a configured or well-known TrustedRouter API/control
// base, so they stay in scope; a caller-supplied absolute URL is in scope
// only when its scheme, host, and effective port exactly match one of those
// bases. Everything else fails closed to a credential-free request:
// unknown hosts, `http://` downgrades of a TrustedRouter hostname,
// non-default ports, non-http(s) schemes, URLs carrying userinfo, and
// unparseable URLs.
//
// The two public-document hosts — `defaultStatusURL` and
// `defaultTrustReleaseURL` — are deliberately NOT in scope. They serve
// unauthenticated JSON, nothing in the SDK authenticates to them, and the
// fetchers that read them (`status()` here, `fetchTrustRelease` in
// Attestation/) build credential-free requests anyway. Leaving them out
// means a hand-written `request(path: "https://status.trustedrouter.com/…")`
// cannot reach them with the account's bearer either.
//
// Mirrors trusted-router-py, where the absolute-URL fetches (`status`,
// `attestation`, `trust_release`) ride the raw HTTP client and the
// credential headers are attached only inside `_request`, which never sees
// an absolute URL — so no absolute-URL fetch there can leak the bearer.

/// The set of URL origins (scheme + host + effective port) that SDK-attached
/// credential headers may be sent to.
struct CredentialHostAllowlist: Sendable {
    /// Normalized origin of one URL. `port` is the effective port: the
    /// explicit one when present, else the scheme default. Only http(s)
    /// schemes have an identity; anything else has none and fails closed.
    private struct HostIdentity: Hashable {
        let scheme: String
        let host: String
        let port: Int

        /// Built from `URL`'s own accessors rather than a `URLComponents`
        /// round-trip: `URL` is the object `URLSession` resolves the
        /// connection from, so on the older Darwin releases this package
        /// still supports — where `URL` uses legacy `NSURL` parsing and
        /// `URLComponents` does not — the origin checked here is the origin
        /// that gets connected to, not a second parser's opinion of it.
        init?(_ url: URL?) {
            guard let url else { return nil }
            // Userinfo is refused outright rather than ignored. A URL like
            // `https://api.trustedrouter.com@evil.example/` is the canonical
            // way to make two parsers disagree about the authority, so no
            // URL carrying userinfo is ever credentialed regardless of which
            // component a given Foundation version reports as the host.
            guard url.user == nil, url.password == nil else { return nil }
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased(),
                  !host.isEmpty
            else { return nil }
            switch scheme {
            case "https": self.port = url.port ?? 443
            case "http": self.port = url.port ?? 80
            default: return nil
            }
            self.scheme = scheme
            self.host = host
        }
    }

    private let identities: Set<HostIdentity>

    /// `configuredBaseURLs` carries the instance's own (possibly custom)
    /// inference and control bases: a host the caller deliberately pointed
    /// the credentialed client at keeps receiving credentials on absolute
    /// URLs too, exactly as it does on every relative request.
    init(configuredBaseURLs: [String]) {
        var urls = configuredBaseURLs
        urls.append(TrustedRouterConstants.defaultAPIBaseURL)
        urls.append(TrustedRouterConstants.defaultControlBaseURL)
        urls.append(contentsOf: TrustedRouterConstants.aliasAPIBaseURLs)
        urls.append(contentsOf: TrustedRouterConstants.regionBaseURLs)
        var identities = Set<HostIdentity>()
        for url in urls {
            if let identity = HostIdentity(URL(string: url)) {
                identities.insert(identity)
            }
        }
        self.identities = identities
    }

    /// True when `url`'s origin exactly matches a configured or well-known
    /// TrustedRouter API/control origin.
    func allowsCredentials(for url: URL) -> Bool {
        guard let identity = HostIdentity(url) else { return false }
        return identities.contains(identity)
    }
}

extension TrustedRouter {
    /// The headers this SDK attaches from its own stored configuration. These
    /// are the ones credential scoping withholds from out-of-scope origins;
    /// a value the caller passes explicitly at the call site (in `headers:`
    /// or `options.extraHeaders`) is the caller's own choice and passes
    /// through untouched.
    static let credentialHeaderNames: Set<String> = [
        "authorization",
        "x-trustedrouter-workspace",
        "idempotency-key"
    ]
}
