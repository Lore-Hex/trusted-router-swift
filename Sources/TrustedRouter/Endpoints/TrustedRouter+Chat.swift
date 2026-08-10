import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
