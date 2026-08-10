import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L7 — ORCHESTRATION BUILDERS. fusion/advisor/selector/mapreduce/subagent
// tool specs plus the fusion runner. Every snake_case parameter key is
// pinned by SDKParityContractTests and must not change.

extension TrustedRouter {

    /**
     * Build a `trustedrouter:fusion` tool spec. Fan a request across a panel of
     * models and have a judge model pick or synthesize one answer. Omit a field
     * to let the gateway default it (`selectionStrategy` defaults to "synthesize").
     * `judgeModel` maps to the fusion `model` parameter.
     */
    public static func fusionTool(
        enabled: Bool? = nil,
        analysisModels: [String]? = nil,
        judgeModel: String? = nil,
        selectionStrategy: String? = nil,
        fallbackJudges: [String]? = nil,
        fallbackFinalModels: [String]? = nil,
        maxCompletionTokens: Int? = nil,
        maxToolCalls: Int? = nil,
        preset: String? = nil,
        panelPrompt: String? = nil,
        synthesisPrompt: String? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let enabled { parameters["enabled"] = enabled }
        if let preset = preset { parameters["preset"] = preset }
        if let analysisModels = analysisModels { parameters["analysis_models"] = analysisModels }
        if let judgeModel = judgeModel { parameters["model"] = judgeModel }
        if let selectionStrategy = selectionStrategy { parameters["selection_strategy"] = selectionStrategy }
        if let fallbackJudges = fallbackJudges { parameters["fallback_judges"] = fallbackJudges }
        if let fallbackFinalModels = fallbackFinalModels { parameters["fallback_final_models"] = fallbackFinalModels }
        if let maxCompletionTokens = maxCompletionTokens { parameters["max_completion_tokens"] = maxCompletionTokens }
        if let maxToolCalls = maxToolCalls { parameters["max_tool_calls"] = maxToolCalls }
        if let panelPrompt = panelPrompt { parameters["panel_prompt"] = panelPrompt }
        if let synthesisPrompt = synthesisPrompt { parameters["synthesis_prompt"] = synthesisPrompt }
        return ["type": "trustedrouter:fusion", "parameters": parameters]
    }

    /// Build a `trustedrouter:advisor` tool spec.
    public static func advisorTool(
        enabled: Bool? = nil,
        depth: Int? = nil,
        workerModels: [String]? = nil,
        advisorModels: [String]? = nil,
        maxGetAdviceCalls: Int? = nil,
        advisorMaxTokens: Int? = nil,
        workerTimeoutMilliseconds: Int? = nil,
        advisorTimeoutMilliseconds: Int? = nil,
        autoInitialAdvice: Bool? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let enabled { parameters["enabled"] = enabled }
        if let depth { parameters["depth"] = depth }
        if let workerModels { parameters["worker_models"] = workerModels }
        if let advisorModels { parameters["advisor_models"] = advisorModels }
        if let maxGetAdviceCalls { parameters["max_get_advice_calls"] = maxGetAdviceCalls }
        if let advisorMaxTokens { parameters["advisor_max_tokens"] = advisorMaxTokens }
        if let workerTimeoutMilliseconds { parameters["worker_timeout_ms"] = workerTimeoutMilliseconds }
        if let advisorTimeoutMilliseconds { parameters["advisor_timeout_ms"] = advisorTimeoutMilliseconds }
        if let autoInitialAdvice { parameters["auto_initial_advice"] = autoInitialAdvice }
        return ["type": "trustedrouter:advisor", "parameters": parameters]
    }

    /// Build a `trustedrouter:selector` tool spec.
    public static func selectorTool(
        enabled: Bool? = nil,
        analysisModels: [String]? = nil,
        selectorModels: [String]? = nil,
        selectorPrompt: String? = nil,
        maxCompletionTokens: Int? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let enabled { parameters["enabled"] = enabled }
        if let analysisModels { parameters["analysis_models"] = analysisModels }
        if let selectorModels { parameters["selector_models"] = selectorModels }
        if let selectorPrompt { parameters["selector_prompt"] = selectorPrompt }
        if let maxCompletionTokens { parameters["max_completion_tokens"] = maxCompletionTokens }
        return ["type": "trustedrouter:selector", "parameters": parameters]
    }

    /// Build a `trustedrouter:mapreduce` tool spec.
    public static func mapReduceTool(
        enabled: Bool? = nil,
        mapperModels: [String]? = nil,
        parallelModels: [String]? = nil,
        reducerModels: [String]? = nil,
        maxParts: Int? = nil,
        mapperPrompt: String? = nil,
        parallelPrompt: String? = nil,
        reducerPrompt: String? = nil,
        maxCompletionTokens: Int? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let enabled { parameters["enabled"] = enabled }
        if let mapperModels { parameters["mapper_models"] = mapperModels }
        if let parallelModels { parameters["parallel_models"] = parallelModels }
        if let reducerModels { parameters["reducer_models"] = reducerModels }
        if let maxParts { parameters["max_parts"] = maxParts }
        if let mapperPrompt { parameters["mapper_prompt"] = mapperPrompt }
        if let parallelPrompt { parameters["parallel_prompt"] = parallelPrompt }
        if let reducerPrompt { parameters["reducer_prompt"] = reducerPrompt }
        if let maxCompletionTokens { parameters["max_completion_tokens"] = maxCompletionTokens }
        return ["type": "trustedrouter:mapreduce", "parameters": parameters]
    }

    /// Build a `trustedrouter:subagent` tool spec.
    public static func subagentTool(
        enabled: Bool? = nil,
        controllerModel: String? = nil,
        model: String? = nil,
        instructions: String? = nil,
        depth: Int? = nil,
        maxSubagentCalls: Int? = nil,
        maxCompletionTokens: Int? = nil,
        temperature: Double? = nil,
        reasoning: Any? = nil,
        tools: [[String: Any]]? = nil
    ) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let enabled { parameters["enabled"] = enabled }
        if let controllerModel { parameters["controller_model"] = controllerModel }
        if let model { parameters["model"] = model }
        if let instructions { parameters["instructions"] = instructions }
        if let depth { parameters["depth"] = depth }
        if let maxSubagentCalls { parameters["max_subagent_calls"] = maxSubagentCalls }
        if let maxCompletionTokens { parameters["max_completion_tokens"] = maxCompletionTokens }
        if let temperature { parameters["temperature"] = temperature }
        if let reasoning { parameters["reasoning"] = reasoning }
        if let tools { parameters["tools"] = tools }
        return ["type": "trustedrouter:subagent", "parameters": parameters]
    }

    /**
     * Run a request through TrustedRouter Fusion: fan it across a panel of
     * models and return one answer chosen/synthesized by a judge model. Returns
     * a ChatCompletion, same as `chatCompletions`. Pass `fallbackJudges` so a
     * single squeamish judge can't sink a prompt.
     */
    public func fusion(
        messages: [[String: Any]],
        analysisModels: [String]? = nil,
        judgeModel: String? = nil,
        selectionStrategy: String? = nil,
        fallbackJudges: [String]? = nil,
        fallbackFinalModels: [String]? = nil,
        maxCompletionTokens: Int? = nil,
        maxToolCalls: Int? = nil,
        preset: String? = nil,
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> ChatCompletion {
        var body = params
        var tools = (body["tools"] as? [[String: Any]]) ?? []
        tools.append(Self.fusionTool(
            analysisModels: analysisModels,
            judgeModel: judgeModel,
            selectionStrategy: selectionStrategy,
            fallbackJudges: fallbackJudges,
            fallbackFinalModels: fallbackFinalModels,
            maxCompletionTokens: maxCompletionTokens,
            maxToolCalls: maxToolCalls,
            preset: preset
        ))
        body["tools"] = tools
        return try await chatCompletions(
            model: TrustedRouterConstants.fusionModel,
            messages: messages,
            options: options,
            params: body,
            provider: provider
        )
    }

    /// `[ChatMessage]` overload for `fusion(...)`.
    public func fusion(
        messages: [ChatMessage],
        analysisModels: [String]? = nil,
        judgeModel: String? = nil,
        selectionStrategy: String? = nil,
        fallbackJudges: [String]? = nil,
        fallbackFinalModels: [String]? = nil,
        maxCompletionTokens: Int? = nil,
        maxToolCalls: Int? = nil,
        preset: String? = nil,
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> ChatCompletion {
        try await fusion(
            messages: try messages.map(messageToDict),
            analysisModels: analysisModels,
            judgeModel: judgeModel,
            selectionStrategy: selectionStrategy,
            fallbackJudges: fallbackJudges,
            fallbackFinalModels: fallbackFinalModels,
            maxCompletionTokens: maxCompletionTokens,
            maxToolCalls: maxToolCalls,
            preset: preset,
            options: options,
            params: params,
            provider: provider
        )
    }
}
