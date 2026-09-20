import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L8 — catalog / metadata endpoints. Control plane: exactly one candidate,
// so failover is structurally impossible here.

extension TrustedRouter {

    /// Lists models matching the optional capability and provider filters.
    public func models(
        openWeights: Bool? = nil,
        providerJurisdiction: String? = nil,
        providerRegion: String? = nil
    ) async throws -> DataList<ModelInfo> {
        return try await request(
            method: "GET",
            path: modelsPath(
                openWeights: openWeights,
                providerJurisdiction: providerJurisdiction,
                providerRegion: providerRegion
            ),
            plane: .control
        )
    }

    /// Lists providers advertised by the control plane.
    public func providers() async throws -> DataList<ProviderInfo> {
        return try await request(method: "GET", path: "/providers", plane: .control)
    }

    /// Lists available routing regions.
    public func regions() async throws -> DataList<RegionInfo> {
        return try await request(method: "GET", path: "/regions", plane: .control)
    }

    /// Fetches the credit balance for the selected workspace.
    public func credits(workspaceId: String? = nil) async throws -> CreditsResponse {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "GET", path: "/credits", options: options, plane: .control)
    }
}

private func modelsPath(
    openWeights: Bool?,
    providerJurisdiction: String?,
    providerRegion: String?
) -> String {
    var queryItems: [URLQueryItem] = []
    if let openWeights = openWeights {
        queryItems.append(URLQueryItem(name: "open_weights", value: openWeights ? "true" : "false"))
    }
    if let providerJurisdiction = providerJurisdiction {
        queryItems.append(URLQueryItem(name: "provider[jurisdiction]", value: providerJurisdiction))
    }
    if let providerRegion = providerRegion {
        queryItems.append(URLQueryItem(name: "provider[region]", value: providerRegion))
    }
    var components = URLComponents()
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let query = components.query, !query.isEmpty else {
        return "/models"
    }
    return "/models?\(query)"
}
