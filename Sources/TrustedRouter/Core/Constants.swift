import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L7 data — compile-time constants pinned by SDKParityContractTests.

/// Compile-time constants for the SDK: version, default endpoints, and models.
public enum TrustedRouterConstants {
    /// SDK version reported in client metadata.
    public static let version = "0.9.0"

    // Use `compiler` rather than `swift`: this identity describes the
    // compiler/toolchain that built the SDK, while `swift` tests the selected
    // language compatibility mode and may be lower under `-swift-version`.
    // Conditional version checks prove only a floor, not the exact patch
    // release, so this reports the highest detected floor (for example,
    // `swift/6.0` for any 6.0.x compiler). This is the single source for the
    // SDK-built User-Agent and the beacon identity, so the SDK's own two
    // identities cannot report different runtimes. A caller can override the
    // inference User-Agent; the server then attributes that request by the
    // caller's string (`client_sdk`/`client_runtime` reflect the override),
    // while the beacon continues to report the SDK's true runtime. The
    // fallback remains valid under the client-telemetry runtime-token grammar.
    #if compiler(>=6.2)
    static let runtime = "swift/6.2"
    #elseif compiler(>=6.1)
    static let runtime = "swift/6.1"
    #elseif compiler(>=6.0)
    static let runtime = "swift/6.0"
    #elseif compiler(>=5.10)
    static let runtime = "swift/5.10"
    #elseif compiler(>=5.9)
    static let runtime = "swift/5.9"
    #else
    static let runtime = "swift/unknown"
    #endif

    /// Default inference API base URL.
    public static let defaultAPIBaseURL = "https://api.trustedrouter.com/v1"
    /// Default control-plane API base URL.
    public static let defaultControlBaseURL = "https://trustedrouter.com/v1"
    /// Default URL of the published image trust policy.
    public static let defaultTrustReleaseURL = "https://trust.trustedrouter.com/trust/gcp-release.json"
    /// Default service status URL.
    public static let defaultStatusURL = "https://status.trustedrouter.com/status.json"
    /// Default regional health-probe timeout, in seconds.
    public static let defaultRegionProbeTimeout: TimeInterval = 1.5
    /// Regional inference gateways eligible for affinity and failover.
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
    /// Routing model identifier for the auto preset.
    public static let autoModel = "trustedrouter/auto"
    /// Routing model identifier for the fast preset.
    public static let fastModel = "trustedrouter/fast"
    /// Routing model identifier for the zdr preset.
    public static let zdrModel = "trustedrouter/zdr"
    /// Routing model identifier for the e2e preset.
    public static let e2eModel = "trustedrouter/e2e"
    /// Routing model identifier for the confidential preset.
    public static let confidentialModel = "trustedrouter/confidential"
    /// Routing model identifier for the eu preset.
    public static let euModel = "trustedrouter/eu"
    /// Routing model identifier for the us preset.
    public static let usModel = "trustedrouter/us"
    /// Routing model identifier for the fusion preset.
    public static let fusionModel = "trustedrouter/fusion"
    /// Routing model identifier for the synth preset.
    public static let synthModel = "trustedrouter/synth"
    /// Routing model identifier for the advisor preset.
    public static let advisorModel = "trustedrouter/advisor"
    /// Routing model identifier for the selector preset.
    public static let selectorModel = "trustedrouter/selector"
    /// Routing model identifier for the mapReduce preset.
    public static let mapReduceModel = "trustedrouter/mapreduce"
    /// Routing model identifier for the subagent preset.
    public static let subagentModel = "trustedrouter/subagent"
    /// Routing model identifier for the socrates preset.
    public static let socratesModel = "trustedrouter/socrates-1.1"
    /// Routing model identifier for the prometheus preset.
    public static let prometheusModel = "trustedrouter/prometheus-2.0"
    /// Routing model identifier for the zeus preset.
    public static let zeusModel = "trustedrouter/zeus-1.0"
    /// Routing model identifier for the athena preset.
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
    /// Fallback judges for the permissive fusion panel.
    public static let fusionFreedomFallbackJudges = [
        "z-ai/glm-5.1",
        "moonshotai/kimi-k2.6",
        "google/gemini-2.5-flash",
        "deepseek/deepseek-v4-flash",
        "google/gemini-3-flash-preview",
        "tencent/hy3-preview"
    ]
}
