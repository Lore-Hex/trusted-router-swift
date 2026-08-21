import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L7 data — compile-time constants pinned by SDKParityContractTests.

/// Compile-time constants for the SDK: version, default endpoints, and models.
public enum TrustedRouterConstants {
    public static let version = "0.7.0"
    public static let defaultAPIBaseURL = "https://api.trustedrouter.com/v1"
    public static let defaultControlBaseURL = "https://trustedrouter.com/v1"
    public static let defaultTrustReleaseURL = "https://trust.trustedrouter.com/trust/gcp-release.json"
    public static let defaultStatusURL = "https://status.trustedrouter.com/status.json"
    public static let defaultRegionProbeTimeout: TimeInterval = 1.5
    public static let regionBaseURLs = [
        "https://api-us-central1.quillrouter.com/v1",
        "https://api-us-east4.quillrouter.com/v1",
        "https://api-europe-west4.quillrouter.com/v1"
    ]
    /// Exact aliases of ``defaultAPIBaseURL``, on separate domains served by
    /// separate DNS providers (trustedrouter.com from Google Cloud DNS, these
    /// two from Route 53).
    ///
    /// The domain is a single point of failure sitting above the whole
    /// deployment: a zone that stops answering, a registrar lock, or a resolver
    /// handing out a stale record takes the API down no matter how many clouds
    /// are behind it. These names resolve to the same attested enclaves, so
    /// falling back to one costs nothing and is invisible to callers.
    ///
    /// They sit at the TAIL of the candidate list, after the regional
    /// endpoints, so a healthy deployment never uses them.
    public static let aliasAPIBaseURLs = [
        "https://api.allyrouter.com/v1",
        "https://api.uptimerouter.com/v1"
    ]
    public static let autoModel = "trustedrouter/auto"
    public static let fastModel = "trustedrouter/fast"
    public static let zdrModel = "trustedrouter/zdr"
    public static let e2eModel = "trustedrouter/e2e"
    public static let confidentialModel = "trustedrouter/confidential"
    public static let euModel = "trustedrouter/eu"
    public static let usModel = "trustedrouter/us"
    public static let fusionModel = "trustedrouter/fusion"
    public static let synthModel = "trustedrouter/synth"
    public static let advisorModel = "trustedrouter/advisor"
    public static let selectorModel = "trustedrouter/selector"
    public static let mapReduceModel = "trustedrouter/mapreduce"
    public static let subagentModel = "trustedrouter/subagent"
    public static let socratesModel = "trustedrouter/socrates-1.1"
    public static let prometheusModel = "trustedrouter/prometheus-2.0"
    public static let zeusModel = "trustedrouter/zeus-1.0"
    public static let athenaModel = "trustedrouter/athena"

    /// Recommended panel + judge fallback chain for maximum willingness to
    /// answer — the configuration that answered all 30 PrometheusBench unsafe
    /// prompts. Pass these to `fusion(...)` (or build your own) for the most
    /// permissive result the panel can produce.
    public static let fusionFreedomPanel = [
        "moonshotai/kimi-k2.7-code",
        "deepseek/deepseek-v4-flash",
        "google/gemini-3.5-flash",
        "google/gemini-3.1-pro-preview",
        "minimax/minimax-m3",
        "z-ai/glm-5.1"
    ]
    public static let fusionFreedomFallbackJudges = [
        "z-ai/glm-5.1",
        "moonshotai/kimi-k2.6",
        "google/gemini-2.5-flash",
        "deepseek/deepseek-v4-flash",
        "google/gemini-3-flash-preview",
        "tencent/hy3-preview"
    ]
}
