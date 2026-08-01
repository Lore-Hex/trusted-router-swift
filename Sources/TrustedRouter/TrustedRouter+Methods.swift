import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension TrustedRouter {
    
    // ---- catalog / metadata ---------------------------------------------
    
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
    
    public func providers() async throws -> DataList<ProviderInfo> {
        return try await request(method: "GET", path: "/providers", plane: .control)
    }
    
    public func regions() async throws -> DataList<RegionInfo> {
        return try await request(method: "GET", path: "/regions", plane: .control)
    }
    
    public func credits(workspaceId: String? = nil) async throws -> CreditsResponse {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "GET", path: "/credits", options: options, plane: .control)
    }
    
    // ---- chat ------------------------------------------------------------
    
    /**
     * OpenAI-compatible chat completion. This method collects all chunks from the
     * gateway (which always streams) and returns a single ChatCompletion object.
     */
    public func chatCompletions(
        model: String = TrustedRouterConstants.autoModel,
        messages: [[String: Any]],
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> ChatCompletion {
        let stream: AsyncThrowingStream<ChatCompletionChunk, Error> = try await chatCompletionsChunks(
            model: model,
            messages: messages,
            options: options,
            params: params,
            provider: provider
        )
        
        var chunks: [ChatCompletionChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return collectCompletion(chunks: chunks)
    }
    
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func chatCompletionsChunks(
        model: String = TrustedRouterConstants.autoModel,
        messages: [[String: Any]],
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        var body = bodyWithProvider(params, provider: provider)
        body["model"] = model
        body["messages"] = messages
        body["stream"] = true

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await rawStreamRequest(
            method: "POST",
            path: "/chat/completions",
            headers: ["accept": "text/event-stream"],
            body: bodyData,
            options: options
        )

        if response.statusCode >= 400 {
            // Drain the body before throwing so callers see the server's
            // actual error message instead of a bare status code.
            throw try await streamingError(bytes: bytes, response: response)
        }

        return iterSseEvents(bytes: bytes, type: ChatCompletionChunk.self)
    }

    /// `[ChatMessage]` overload — encodes the typed messages to the dict
    /// shape the API expects and forwards to the untyped path.
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func chatCompletionsChunks(
        model: String = TrustedRouterConstants.autoModel,
        messages: [ChatMessage],
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        try await chatCompletionsChunks(
            model: model,
            messages: try messages.map(messageToDict),
            options: options,
            params: params,
            provider: provider
        )
    }

    /// `[ChatMessage]` overload — non-streaming variant.
    public func chatCompletions(
        model: String = TrustedRouterConstants.autoModel,
        messages: [ChatMessage],
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> ChatCompletion {
        try await chatCompletions(
            model: model,
            messages: try messages.map(messageToDict),
            options: options,
            params: params,
            provider: provider
        )
    }

    /** Simple helper to yield only the text deltas from a chat completion stream. */
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func chatCompletionsText(
        model: String = TrustedRouterConstants.autoModel,
        messages: [[String: Any]],
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> AsyncThrowingStream<String, Error> {
        let chunks = try await chatCompletionsChunks(
            model: model,
            messages: messages,
            options: options,
            params: params,
            provider: provider
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in chunks {
                        if let content = chunk.choices.first?.delta?.content, !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // ---- fusion ----------------------------------------------------------

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

    // ---- other endpoints ---------------------------------------------

    public func embeddings(
        model: String,
        input: Any,
        encodingFormat: String? = nil,
        dimensions: Int? = nil,
        user: String? = nil,
        options: PerCallOptions = PerCallOptions(),
        provider: ProviderPreferences? = nil
    ) async throws -> EmbeddingResponse {
        var body = bodyWithProvider(
            ["model": model, "input": input],
            provider: provider
        )
        if let encodingFormat = encodingFormat { body["encoding_format"] = encodingFormat }
        if let dimensions = dimensions { body["dimensions"] = dimensions }
        if let user = user { body["user"] = user }
        
        return try await request(method: "POST", path: "/embeddings", body: body, options: options)
    }
    
    public func messages(
        model: String,
        messages: [[String: Any]],
        maxTokens: Int = 1024,
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> MessageResponse {
        var body = bodyWithProvider(params, provider: provider)
        body["model"] = model
        body["messages"] = messages
        body["max_tokens"] = maxTokens
        
        return try await request(method: "POST", path: "/messages", body: body, options: options)
    }
    
    public func responses(
        model: String = TrustedRouterConstants.autoModel,
        input: Any,
        instructions: String? = nil,
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> ResponseObject {
        var body = bodyWithProvider(params, provider: provider)
        body["model"] = model
        body["input"] = input
        body["stream"] = false
        if let instructions = instructions {
            body["instructions"] = instructions
        }
        
        return try await request(method: "POST", path: "/responses", body: body, options: options)
    }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    public func responsesEvents(
        model: String = TrustedRouterConstants.autoModel,
        input: Any,
        instructions: String? = nil,
        options: PerCallOptions = PerCallOptions(),
        params: [String: Any] = [:],
        provider: ProviderPreferences? = nil
    ) async throws -> AsyncThrowingStream<[String: Any], Error> {
        var body = bodyWithProvider(params, provider: provider)
        body["model"] = model
        body["input"] = input
        body["stream"] = true
        if let instructions = instructions {
            body["instructions"] = instructions
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await rawStreamRequest(
            method: "POST",
            path: "/responses",
            headers: ["accept": "text/event-stream"],
            body: bodyData,
            options: options
        )

        if response.statusCode >= 400 {
            throw try await streamingError(bytes: bytes, response: response)
        }

        return iterSseEvents(bytes: bytes)
    }

    // MARK: - helpers

    /// Drain `bytes` into a `Data` buffer and classify as a
    /// `TrustedRouterError` using the same logic as non-streaming requests.
    /// Used when a stream endpoint returns a 4xx/5xx status before any SSE
    /// frames are sent — the body usually contains the actual error message.
    @available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
    private func streamingError(
        bytes: TrustedRouterByteStream,
        response: HTTPURLResponse
    ) async throws -> TrustedRouterError {
        var collected = Data()
        do {
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 64 * 1024 { break } // safety cap
            }
        } catch {
            // Body drained as much as we could; classify with what we got.
        }
        return classifyErrorPublic(statusCode: response.statusCode, data: collected, response: response)
    }

    /// Convert a typed `ChatMessage` to the `[String: Any]` form the gateway
    /// accepts. Round-tripping through JSONEncoder/JSONSerialization keeps
    /// the snake-case key conversion in one place.
    private func messageToDict(_ message: ChatMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrustedRouterError.internalError("could not encode ChatMessage")
        }
        return obj
    }
    
    public func responsesInputTokens(
        model: String = TrustedRouterConstants.autoModel,
        input: Any,
        instructions: String? = nil,
        workspaceId: String? = nil,
        params: [String: Any] = [:]
    ) async throws -> ResponseInputTokens {
        var body = params
        body["model"] = model
        body["input"] = input
        body["stream"] = false
        if let instructions = instructions {
            body["instructions"] = instructions
        }
        
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "POST", path: "/responses/input_tokens", body: body, options: options)
    }

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
        return try await request(method: "POST", path: "/broadcast/destinations", body: body, options: options, plane: .control)
    }
    
    public func getBroadcastDestination(id: String, workspaceId: String? = nil) async throws -> BroadcastDestination {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "GET", path: "/broadcast/destinations/\(id)", options: options, plane: .control)
    }
    
    public func updateBroadcastDestination(id: String, patch: [String: Any], workspaceId: String? = nil) async throws -> BroadcastDestination {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "PATCH", path: "/broadcast/destinations/\(id)", body: patch, options: options, plane: .control)
    }
    
    public func deleteBroadcastDestination(id: String, workspaceId: String? = nil) async throws -> EmptyResponse {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "DELETE", path: "/broadcast/destinations/\(id)", options: options, plane: .control)
    }
    
    public func testBroadcastDestination(id: String, workspaceId: String? = nil) async throws -> EmptyResponse {
        var options = PerCallOptions()
        options.workspaceId = workspaceId
        return try await request(method: "POST", path: "/broadcast/destinations/\(id)/test", options: options, plane: .control)
    }
    
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
        // Return raw dict for status as it's highly dynamic
        let data: Data = try await request(method: "GET", path: url)
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }

    /**
     * Roll a list of ChatCompletionChunk frames into a single ChatCompletion object.
     * Mirrors the JS/Python collect_completion helpers.
     */
    public func collectCompletion(chunks: [ChatCompletionChunk]) -> ChatCompletion {
        if chunks.isEmpty {
            return ChatCompletion(
                id: "",
                object: "chat.completion",
                created: nil,
                model: nil,
                choices: [
                    ChatCompletion.Choice(
                        index: 0,
                        message: ChatCompletion.Choice.Message(role: "assistant", content: ""),
                        finishReason: "stop"
                    )
                ],
                usage: nil
            )
        }
        
        var content = ""
        var finishReason: String? = nil
        for chunk in chunks {
            if let choice = chunk.choices.first {
                if let deltaContent = choice.delta?.content {
                    content += deltaContent
                }
                if let reason = choice.finishReason {
                    finishReason = reason
                }
            }
        }
        
        let last = chunks.last!
        return ChatCompletion(
            id: last.id ?? "",
            object: "chat.completion",
            created: last.created,
            model: last.model,
            choices: [
                ChatCompletion.Choice(
                    index: 0,
                    message: ChatCompletion.Choice.Message(role: "assistant", content: content),
                    finishReason: finishReason ?? "stop"
                )
            ],
            usage: nil
        )
    }
}

private func bodyWithProvider(
    _ params: [String: Any],
    provider: ProviderPreferences?
) -> [String: Any] {
    var body = params
    if let provider {
        body["provider"] = provider.value
    }
    return body
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
