import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L8 — billing, auth-session, activity, and status endpoints.

extension TrustedRouter {

    public func billingCheckout(
        amount: Any,
        paymentMethod: String? = nil,
        successUrl: String? = nil,
        cancelUrl: String? = nil,
        options: PerCallOptions = PerCallOptions()
    ) async throws -> CheckoutResponse {
        var body: [String: Any] = ["amount": amount]
        if let paymentMethod = paymentMethod { body["payment_method"] = paymentMethod }
        if let successUrl = successUrl { body["success_url"] = successUrl }
        if let cancelUrl = cancelUrl { body["cancel_url"] = cancelUrl }

        if body["workspace_id"] == nil && options.workspaceId != nil {
            body["workspace_id"] = options.workspaceId
        }
        return try await request(
            method: "POST", path: "/billing/checkout", body: body,
            options: automaticIdempotencyOptions(options), plane: .control
        )
    }

    public func authSession() async throws -> AuthSessionResponse {
        return try await request(method: "GET", path: "/auth/session", plane: .control)
    }

    public func logout() async throws -> EmptyResponse {
        return try await request(
            method: "POST", path: "/auth/logout",
            options: automaticIdempotencyOptions(PerCallOptions()), plane: .control
        )
    }

    public func activity(params: [String: Any] = [:]) async throws -> ActivityResponse {
        var queryItems: [URLQueryItem] = []
        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: "\(value)"))
        }
        var urlComponents = URLComponents()
        urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems
        let queryStr = urlComponents.query ?? ""
        let path = queryStr.isEmpty ? "/activity" : "/activity?\(queryStr)"

        return try await request(method: "GET", path: path, plane: .control)
    }

    public func status(url: String = TrustedRouterConstants.defaultStatusURL) async throws -> [String: Any] {
        // The status page is a public, unauthenticated document, so this is a
        // single-shot request that carries none of the SDK-attached credential
        // headers, like the Attestation/ fetchers (`attestation()`,
        // `fetchTrustRelease`) rather than the credentialed `request<T>` path.
        // Mirrors trusted-router-py, where `status()` is a bare
        // `self._client.get(url)` on the raw HTTP client — single-shot, and
        // never touching the `authorization` / workspace / idempotency headers
        // that live only inside py's `_request`. The account's bearer token is
        // never sent to a status host, not even the default TrustedRouter one.
        //
        // Client-wide *non*-credential defaults (tracing, proxy routing) do
        // still apply, exactly as on every other request this client makes.
        guard let statusURL = URL(string: url) else {
            throw TrustedRouterError.internalError("Invalid status URL: \(url)")
        }
        var req = URLRequest(url: statusURL)
        // Client-wide default headers (tracing, proxy routing) still apply;
        // only the credential headers are withheld, on every host.
        for (name, value) in buildHeaders(includeCredentials: false) {
            req.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await credentialFreeURLSession.trustedRouterData(for: req)
        let httpResponse = try Self.httpOnly(response)
        if !(200..<300).contains(httpResponse.statusCode) {
            // Reuse the shared classifier so the public error taxonomy
            // (.authentication / .rateLimit with Retry-After / …) and the
            // server's message and payload survive this path.
            throw classifyError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
        }
        // Return raw dict for status as it's highly dynamic
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }
}
