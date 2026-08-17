import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L4 — CREDENTIAL SCOPE. Decides whether a resolved request URL may carry
// the SDK-attached credential headers (`authorization`,
// `x-trustedrouter-workspace`, `idempotency-key`). Relative paths always
// resolve against a configured or well-known TrustedRouter base, so they
// stay in scope; a caller-supplied absolute URL is in scope only when its
// scheme, host, and effective port exactly match a known TrustedRouter
// endpoint. Everything else fails closed to a credential-free request:
// unknown hosts, `http://` downgrades of a TrustedRouter hostname,
// non-default ports, non-http(s) schemes, and unparseable URLs.
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

        init?(_ components: URLComponents?) {
            guard let components,
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(),
                  !host.isEmpty
            else { return nil }
            switch scheme {
            case "https": self.port = components.port ?? 443
            case "http": self.port = components.port ?? 80
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
        urls.append(TrustedRouterConstants.defaultStatusURL)
        urls.append(TrustedRouterConstants.defaultTrustReleaseURL)
        urls.append(contentsOf: TrustedRouterConstants.aliasAPIBaseURLs)
        urls.append(contentsOf: TrustedRouterConstants.regionBaseURLs)
        var identities = Set<HostIdentity>()
        for url in urls {
            if let identity = HostIdentity(URLComponents(string: url)) {
                identities.insert(identity)
            }
        }
        self.identities = identities
    }

    /// True when `url`'s origin exactly matches a known TrustedRouter
    /// endpoint. Both sides are parsed by Foundation, so the origin compared
    /// here is the origin `URLSession` connects to — userinfo confusion
    /// (`https://api.trustedrouter.com@evil.example/`) resolves to the real
    /// connect host and fails the match.
    func allowsCredentials(for url: URL) -> Bool {
        guard let identity = HostIdentity(URLComponents(url: url, resolvingAgainstBaseURL: true)) else {
            return false
        }
        return identities.contains(identity)
    }
}
