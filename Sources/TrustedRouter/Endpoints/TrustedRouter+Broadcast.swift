import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L8 — broadcast destination CRUD. Control plane: these POSTs intentionally
// get NO auto-minted idempotency key (see the engine's inference-only
// predicate).

extension TrustedRouter {

    public func broadcastDestinations(workspaceId: String? = nil) async throws -> DataList<BroadcastDestination> {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "GET", path: "/broadcast/destinations", options: options, plane: .control)
    }

    public func createBroadcastDestination(
        type: String,
        name: String = "Broadcast destination",
        endpoint: String? = nil,
        enabled: Bool = true,
        includeContent: Bool = false,
        method: String = "POST",
        headers: [String: String]? = nil,
        apiKey: String? = nil,
        workspaceId: String? = nil
    ) async throws -> BroadcastDestination {
        var body: [String: Any] = [
            "type": type,
            "name": name,
            "enabled": enabled,
            "include_content": includeContent,
            "method": method
        ]
        if let endpoint = endpoint { body["endpoint"] = endpoint }
        if let headers = headers { body["headers"] = headers }
        if let apiKey = apiKey { body["api_key"] = apiKey }

        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(
            method: "POST", path: "/broadcast/destinations", body: body,
            options: automaticIdempotencyOptions(options), plane: .control
        )
    }

    public func getBroadcastDestination(id: String, workspaceId: String? = nil) async throws -> BroadcastDestination {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "GET", path: "/broadcast/destinations/\(id)", options: options, plane: .control)
    }

    public func updateBroadcastDestination(id: String, patch: [String: Any], workspaceId: String? = nil) async throws -> BroadcastDestination {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(
            method: "PATCH", path: "/broadcast/destinations/\(id)", body: patch,
            options: automaticIdempotencyOptions(options), plane: .control
        )
    }

    public func deleteBroadcastDestination(id: String, workspaceId: String? = nil) async throws -> EmptyResponse {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(
            method: "DELETE", path: "/broadcast/destinations/\(id)",
            options: automaticIdempotencyOptions(options), plane: .control
        )
    }

    public func testBroadcastDestination(id: String, workspaceId: String? = nil) async throws -> EmptyResponse {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(
            method: "POST", path: "/broadcast/destinations/\(id)/test",
            options: automaticIdempotencyOptions(options), plane: .control
        )
    }
}
