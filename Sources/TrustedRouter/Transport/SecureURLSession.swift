import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-task follow-up policy. Redirects are surfaced as their original 3xx,
/// and HTTP authentication challenges are cancelled, so URLSession cannot
/// create hidden physical sends behind the transport engine's accounting.
/// TLS server-trust evaluation remains in Foundation's default handler.
final class TrustedRouterRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var authenticationResponse: HTTPURLResponse?
    private var authenticationStatusCode: Int?

    var blockedAuthenticationResponse: HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return authenticationResponse
    }

    var blockedAuthenticationStatusCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return authenticationStatusCode
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
            == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Origin and proxy HTTP auth are follow-up mechanisms just like
            // redirects. Never consult session credential storage/delegates
            // or replay this SDK attempt with ambient credentials.
            let response = challenge.failureResponse as? HTTPURLResponse
            lock.lock()
            authenticationStatusCode = response?.statusCode
                ?? (challenge.protectionSpace.isProxy() ? 407 : 401)
            if let response {
                authenticationResponse = response
            }
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

extension URLSession {
    /// Clone transport configuration without the caller's session delegate or
    /// ambient credential store. Session-wide NTLM/Negotiate/client-certificate
    /// challenges otherwise bypass the per-task blocker and can create hidden
    /// physical sends. Cookie behavior, proxies, protocol classes, cache,
    /// timeouts, and benign default headers remain configured as supplied.
    func trustedRouterTransportCopy() -> URLSession {
        let copied = configuration.copy() as! URLSessionConfiguration
        copied.urlCredentialStorage = nil
        return URLSession(configuration: copied)
    }

    func trustedRouterData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let delegate = TrustedRouterRedirectBlocker()
        do {
            return try await data(for: request, delegate: delegate)
        } catch {
            // Cancelling an HTTP-auth challenge is the only Foundation
            // disposition that guarantees no second physical send. It also
            // reports NSURLErrorCancelled instead of returning the original
            // 401/407, so restore that response (without inventing a body)
            // for the SDK's normal status classifier and retry accounting.
            if let response = delegate.blockedAuthenticationResponse {
                return (Data(), response)
            }
            if let statusCode = delegate.blockedAuthenticationStatusCode {
                throw TrustedRouterError.authentication(
                    statusCode: statusCode,
                    message: "HTTP authentication challenge refused",
                    payload: nil
                )
            }
            throw error
        }
    }

    /// Credential-free metadata send with a final request-level scrub.
    func trustedRouterCredentialFreeData(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        var scrubbed = request
        TrustedRouter.scrubCredentialHeaders(from: &scrubbed)
        return try await trustedRouterData(for: scrubbed)
    }

    #if !os(Linux)
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    func trustedRouterBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let delegate = TrustedRouterRedirectBlocker()
        do {
            return try await bytes(for: request, delegate: delegate)
        } catch {
            if let statusCode = delegate.blockedAuthenticationStatusCode {
                // AsyncBytes cannot be synthesized. Throwing a typed SDK
                // error makes the transport engine treat this as the original
                // terminal HTTP authentication response, never a retryable
                // ambiguous socket failure.
                throw TrustedRouterError.authentication(
                    statusCode: statusCode,
                    message: HTTPURLResponse.localizedString(forStatusCode: statusCode),
                    payload: nil
                )
            }
            throw error
        }
    }
    #endif

    /// Clone the caller's transport configuration while removing ambient
    /// authentication stores and defaults. Used only for public metadata and
    /// OAuth code exchange paths that promise to send no client credentials.
    func trustedRouterCredentialFreeCopy() -> URLSession {
        let copied = configuration.copy() as! URLSessionConfiguration
        var headers = copied.httpAdditionalHeaders ?? [:]
        for key in Array(headers.keys)
            where TrustedRouter.credentialHeaderNames.contains(
                String(describing: key).lowercased()
            ) {
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
