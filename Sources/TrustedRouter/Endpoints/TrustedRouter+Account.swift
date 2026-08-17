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
        return try await request(method: "POST", path: "/billing/checkout", body: body, options: options, plane: .control)
    }

    public func authSession() async throws -> AuthSessionResponse {
        return try await request(method: "GET", path: "/auth/session", plane: .control)
    }

    public func logout() async throws -> EmptyResponse {
        return try await request(method: "POST", path: "/auth/logout", plane: .control)
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
        // The status page is a public, unauthenticated document: build a
        // bare, credential-free, single-shot request exactly like the
        // Attestation/ fetchers (`attestation()`, `fetchTrustRelease`)
        // instead of riding the credentialed `request<T>` path. This mirrors
        // trusted-router-py, where `status()` rides the raw HTTP client and
        // never sees the `authorization` / workspace / idempotency headers —
        // the account's bearer token is never sent to a status host, not
        // even the default TrustedRouter one.
        guard let statusURL = URL(string: url) else {
            throw TrustedRouterError.internalError("Invalid status URL: \(url)")
        }
        var req = URLRequest(url: statusURL)
        req.setValue("trusted-router-swift/\(TrustedRouterConstants.version)", forHTTPHeaderField: "user-agent")

        let (data, response) = try await urlSession.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrustedRouterError.internalError("Non-HTTP response")
        }
        if httpResponse.statusCode >= 400 {
            throw TrustedRouterError.generic(statusCode: httpResponse.statusCode, message: "Status fetch failed", payload: nil)
        }
        // Return raw dict for status as it's highly dynamic
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }
}
