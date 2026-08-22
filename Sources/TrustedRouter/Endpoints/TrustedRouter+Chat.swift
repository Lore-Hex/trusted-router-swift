import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pull adapter from typed chat chunks to non-empty text deltas. Keeping the
/// iterator in a cursor avoids an eager producer task and continuation queue.
private final class ChatTextCursor: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<ChatCompletionChunk, Error>.AsyncIterator

    init(chunks: AsyncThrowingStream<ChatCompletionChunk, Error>) {
        self.iterator = chunks.makeAsyncIterator()
    }

    func next() async throws -> String? {
        while let chunk = try await iterator.next() {
            try Task.checkCancellation()
            if let content = chunk.choices.first?.delta?.content, !content.isEmpty {
                return content
            }
        }
        return nil
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
func chatTextStream(
    from chunks: AsyncThrowingStream<ChatCompletionChunk, Error>
) -> AsyncThrowingStream<String, Error> {
    let cursor = ChatTextCursor(chunks: chunks)
    return AsyncThrowingStream(unfolding: {
        try await cursor.next()
    })
}

// L8 — chat endpoints. Plane selection + delegation only; the retry and
// failover semantics live entirely in the transport engine.

extension TrustedRouter {

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
        guard chunks.contains(where: { !$0.choices.isEmpty }) else {
            throw TrustedRouterError.invalidResponse(
                "TrustedRouter chat stream completed without a choice"
            )
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
        let effectiveOptions = automaticIdempotencyOptions(options)
        let (bytes, response, recorder) = try await rawStreamRequestWithRecorder(
            method: "POST",
            path: "/chat/completions",
            headers: ["accept": "text/event-stream"],
            body: bodyData,
            options: effectiveOptions
        )

        if !(200..<300).contains(response.statusCode) {
            // Drain the body before throwing so callers see the server's
            // actual error message instead of a bare status code.
            let result = try await streamingError(
                bytes: bytes, response: response, recorder: recorder
            )
            recorder?.finish()
            throw result
        }

        return makeTypedSSEEvents(
            bytes: bytes, type: ChatCompletionChunk.self, recorder: recorder
        )
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
        return chatTextStream(from: chunks)
    }

    /// Convert a typed `ChatMessage` to the `[String: Any]` form the gateway
    /// accepts. Round-tripping through JSONEncoder/JSONSerialization keeps
    /// the snake-case key conversion in one place.
    func messageToDict(_ message: ChatMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrustedRouterError.internalError("could not encode ChatMessage")
        }
        return obj
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

        var collected: [Int: CollectedChatChoice] = [:]
        for chunk in chunks {
            for (position, choice) in chunk.choices.enumerated() {
                let index = choice.index ?? position
                var result = collected[index] ?? CollectedChatChoice()
                if let delta = choice.delta {
                    if let role = delta.role { result.role = role }
                    if let content = delta.content { result.content += content }
                    if let refusal = delta.refusal { result.refusal += refusal }
                    if let reasoning = delta.reasoning { result.reasoning += reasoning }
                    if let reasoningContent = delta.reasoningContent {
                        result.reasoningContent += reasoningContent
                    }
                    if let functionCall = delta.functionCall {
                        result.functionCall = mergeFunctionCall(
                            result.functionCall, with: functionCall
                        )
                    }
                    for (toolPosition, incoming) in (delta.toolCalls ?? []).enumerated() {
                        let toolIndex = incoming.index ?? toolPosition
                        var tool = result.toolCalls[toolIndex]
                            ?? ChatToolCall(index: toolIndex)
                        tool.id = incoming.id ?? tool.id
                        tool.type = incoming.type ?? tool.type
                        if let function = incoming.function {
                            tool.function = mergeFunctionCall(tool.function, with: function)
                        }
                        result.toolCalls[toolIndex] = tool
                    }
                }
                if let reason = choice.finishReason {
                    result.finishReason = reason
                }
                result.logprobs = choice.logprobs ?? result.logprobs
                collected[index] = result
            }
        }

        let choices = collected.keys.sorted().map { index -> ChatCompletion.Choice in
            let result = collected[index]!
            let tools = result.toolCalls.isEmpty
                ? nil
                : result.toolCalls.keys.sorted().map { result.toolCalls[$0]! }
            return ChatCompletion.Choice(
                index: index,
                message: ChatCompletion.Choice.Message(
                    role: result.role,
                    content: result.content.isEmpty ? nil : result.content,
                    refusal: result.refusal.isEmpty ? nil : result.refusal,
                    reasoning: result.reasoning.isEmpty ? nil : result.reasoning,
                    reasoningContent: result.reasoningContent.isEmpty
                        ? nil : result.reasoningContent,
                    toolCalls: tools,
                    functionCall: result.functionCall
                ),
                finishReason: result.finishReason,
                logprobs: result.logprobs
            )
        }
        return ChatCompletion(
            id: chunks.reversed().compactMap(\.id).first ?? "",
            object: "chat.completion",
            created: chunks.reversed().compactMap(\.created).first,
            model: chunks.reversed().compactMap(\.model).first,
            systemFingerprint: chunks.reversed().compactMap(\.systemFingerprint).first,
            choices: choices,
            usage: chunks.reversed().compactMap(\.usage).first
        )
    }
}

private struct CollectedChatChoice {
    var role = "assistant"
    var content = ""
    var refusal = ""
    var reasoning = ""
    var reasoningContent = ""
    var functionCall: ChatFunctionCall?
    var toolCalls: [Int: ChatToolCall] = [:]
    var finishReason: String?
    var logprobs: JSONValue?
}

private func mergeFunctionCall(
    _ current: ChatFunctionCall?, with incoming: ChatFunctionCall
) -> ChatFunctionCall {
    ChatFunctionCall(
        name: incoming.name ?? current?.name,
        arguments: (current?.arguments ?? "") + (incoming.arguments ?? "")
    )
}
