import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L2 — CANDIDATE SET. Builds the ordered inference base-URL candidate list
// once per logical call. Aliases are appended ONLY when the configured base
// equals the default host after trailing-slash normalization on BOTH sides;
// a custom base URL is never rewritten. The list stays >1 for default-host
// clients even with an injected URLSession and even when every regional
// probe fails — no region answering is precisely when the aliases matter.

func trimTrailingSlashes(_ value: String) -> String {
    var trimmed = value
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed
}

/// The primary API host followed by its alias domains.
///
/// This list must have MORE THAN ONE entry or failover cannot engage at all:
/// every advance in the transport engine is guarded by
/// `candidateIndex < candidates.count - 1`, so a single-entry list makes the
/// transport-error and 502/503/504 handling unreachable. That was the state
/// for any client with an injected `URLSession`, which is every client that
/// configures its own caching, timeouts, or delegate — the regional selector
/// is disabled for those, and the fallback was a one-element list.
///
/// Aliases are appended only for the default API host. A caller who passed
/// their own base URL — a private deployment, a test server, a regional pin —
/// gets exactly that; silently redirecting that traffic to a public alias
/// would be worse than failing.
func aliasFailoverURLs(primaryBaseURL: String, regionalFailover: Bool) -> [String] {
    // Both sides go through the same normalization: comparing a stored base
    // URL against the raw constant is how this silently degrades to one entry.
    let primary = trimTrailingSlashes(primaryBaseURL)
    guard regionalFailover,
          primary == trimTrailingSlashes(TrustedRouterConstants.defaultAPIBaseURL)
    else { return [primary] }
    var seen = Set<String>()
    return ([primary] + TrustedRouterConstants.aliasAPIBaseURLs.map(trimTrailingSlashes))
        .filter { seen.insert($0).inserted }
}

private actor RegionalProbeRace {
    private var remaining: Int
    private var resolved = false
    private var result: String?
    private var waiter: CheckedContinuation<String?, Never>?

    init(count: Int) {
        self.remaining = count
    }

    func record(_ healthyBaseURL: String?) {
        guard !resolved else { return }
        if let healthyBaseURL {
            resolve(healthyBaseURL)
            return
        }
        remaining -= 1
        if remaining == 0 {
            resolve(nil)
        }
    }

    func firstHealthy() async -> String? {
        if resolved { return result }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    private func resolve(_ value: String?) {
        resolved = true
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}

actor RegionalEndpointSelector {
    private let primaryBaseURL: String
    private let urlSession: URLSession
    private let timeout: TimeInterval
    private var ranked: [String]?
    private var rankingTask: Task<[String], Never>?

    init(primaryBaseURL: String, urlSession: URLSession, timeout: TimeInterval) {
        self.primaryBaseURL = primaryBaseURL
        self.urlSession = urlSession
        self.timeout = max(0.1, timeout)
    }

    func endpoints() async -> [String] {
        if let ranked { return ranked }
        if let rankingTask { return await rankingTask.value }
        let task = Task { [primaryBaseURL, urlSession, timeout] in
            var seen = Set<String>()
            let candidates = (TrustedRouterConstants.regionBaseURLs + [primaryBaseURL]).filter {
                seen.insert($0).inserted
            }
            let race = RegionalProbeRace(count: candidates.count)
            for baseURL in candidates {
                Task {
                    guard let url = URL(
                        string: baseURL.replacingOccurrences(
                            of: "/v1$",
                            with: "",
                            options: .regularExpression
                        ) + "/health"
                    ) else {
                        await race.record(nil)
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.timeoutInterval = timeout
                    do {
                        let (_, response) = try await urlSession
                            .trustedRouterCredentialFreeData(for: request)
                        guard let http = response as? HTTPURLResponse,
                              http.statusCode == 200 || http.statusCode == 401
                        else {
                            await race.record(nil)
                            return
                        }
                        await race.record(baseURL)
                    } catch {
                        await race.record(nil)
                    }
                }
            }
            let winner = await race.firstHealthy()
            // No region answering is precisely when the aliases matter, so this
            // must not collapse to a single host — that would delete failover
            // at the exact moment it is needed.
            let aliases = aliasFailoverURLs(
                primaryBaseURL: primaryBaseURL, regionalFailover: true
            )
            guard let winner else { return aliases }
            seen.removeAll(keepingCapacity: true)
            return ([winner, primaryBaseURL] + candidates + aliases).filter {
                seen.insert($0).inserted
            }
        }
        rankingTask = task
        let result = await task.value
        ranked = result
        rankingTask = nil
        return result
    }
}
