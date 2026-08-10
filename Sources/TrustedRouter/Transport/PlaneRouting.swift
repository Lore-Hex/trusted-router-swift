import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L2 — PLANE ROUTER. Chooses which base host a path resolves against.
// The inference plane may carry a multi-entry candidate list (see
// EndpointCandidates.swift); the control plane and absolute-URL fetches
// always resolve to exactly one URL, so failover is structurally impossible
// there — the candidate list length is the gate, not a second flag.

/// Request routing plane for methods that need to choose between inference
/// and control/metadata hosts.
public enum TrustedRouterRequestPlane: Sendable {
    case inference
    case control
}

/// True when `path` is a relative inference-plane path — the only case that
/// resolves against the (possibly multi-entry) inference candidate list.
/// Absolute URLs (a scheme is present) and control-plane paths never do.
func usesInferenceBase(path: String, plane: TrustedRouterRequestPlane) -> Bool {
    if plane != .inference {
        return false
    }
    return URLComponents(string: path)?.scheme == nil
}

extension TrustedRouter {
    func baseURL(for plane: TrustedRouterRequestPlane) -> String {
        switch plane {
        case .inference: return baseUrl
        case .control: return controlBaseURL
        }
    }

    func requestURLString(
        path: String,
        plane: TrustedRouterRequestPlane,
        baseURLOverride: String? = nil
    ) -> String {
        if let components = URLComponents(string: path), components.scheme != nil {
            return path
        }
        let relativePath = path.replacingOccurrences(of: "^/+", with: "", options: .regularExpression)
        return "\(baseURLOverride ?? baseURL(for: plane))/\(relativePath)"
    }
}
