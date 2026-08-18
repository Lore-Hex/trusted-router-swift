import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L4 — CREDENTIAL SCOPE. Decides whether a resolved request URL may carry
// credential-shaped headers (`authorization`, proxy authorization, cookies,
// API/workspace keys, idempotency, and SDK telemetry). Relative paths always
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
        /// round-trip. `URL` is the object handed to `URLSession`, so this
        /// reads the authority from the same value the transport is given
        /// rather than from a second parse of the string — which matters on
        /// the older Darwin releases this package supports, where `URL` uses
        /// legacy `NSURL` parsing and `URLComponents` does not. It is not a
        /// claim to model the transport's own resolution: the guarantee comes
        /// from the exact-match allowlist plus the refusals below, which fail
        /// closed on anything the two parsers could disagree about.
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
    /// Credential-shaped names stripped from every credential-free request.
    /// This is intentionally broader than the three fields minted by the SDK:
    /// client defaults are ambient rather than authorization for a public
    /// metadata host. Explicit per-call headers can still authenticate a
    /// generic absolute request; metadata entry points expose no such escape
    /// hatch and perform a final request scrub immediately before sending.
    static let credentialHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "cookie2",
        "x-api-key",
        "x-tr-client",
        "x-trustedrouter-workspace",
        "idempotency-key"
    ]

    /// Final, case-insensitive request-level scrub for public metadata paths.
    /// The companion credential-free URLSession copy also removes session
    /// defaults, cookie/credential stores, and authentication delegates.
    static func scrubCredentialHeaders(from request: inout URLRequest) {
        for name in credentialHeaderNames {
            request.setValue(nil, forHTTPHeaderField: name)
        }
    }
}
