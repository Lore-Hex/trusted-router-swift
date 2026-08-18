import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-task redirect policy. Redirects are surfaced to the SDK as their
/// original 3xx response so URLSession cannot replay prompts or credential
/// headers to a different origin behind the transport engine's back.
final class TrustedRouterRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = TrustedRouterRedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension URLSession {
    func trustedRouterData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: TrustedRouterRedirectBlocker.shared)
    }

    #if !os(Linux)
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    func trustedRouterBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await bytes(for: request, delegate: TrustedRouterRedirectBlocker.shared)
    }
    #endif

    /// Clone the caller's transport configuration while removing ambient
    /// authentication stores and defaults. Used only for public metadata and
    /// OAuth code exchange paths that promise to send no client credentials.
    func trustedRouterCredentialFreeCopy() -> URLSession {
        let copied = configuration.copy() as! URLSessionConfiguration
        var headers = copied.httpAdditionalHeaders ?? [:]
        let forbidden = Set([
            "authorization", "proxy-authorization", "cookie", "cookie2",
            "x-api-key", "x-tr-client", "x-trustedrouter-workspace",
            "idempotency-key"
        ])
        for key in headers.keys where forbidden.contains(String(describing: key).lowercased()) {
            headers.removeValue(forKey: key)
        }
        copied.httpAdditionalHeaders = headers
        copied.httpCookieStorage = nil
        copied.httpShouldSetCookies = false
        copied.urlCredentialStorage = nil
        // Deliberately do not copy the session delegate: authentication
        // challenge callbacks are another ambient credential source. The
        // configuration (including protocolClasses/proxies/cache policy) is
        // retained, which keeps injected test and enterprise transports.
        return URLSession(configuration: copied)
    }
}
