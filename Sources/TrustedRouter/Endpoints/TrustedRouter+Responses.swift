import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// L8 — embeddings, Anthropic-style messages, and the Responses API.

extension TrustedRouter {

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

        return try await request(
            method: "POST", path: "/embeddings", body: body,
            options: automaticIdempotencyOptions(options)
        )
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

        return try await request(
            method: "POST", path: "/messages", body: body,
            options: automaticIdempotencyOptions(options)
        )
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

        return try await request(
            method: "POST", path: "/responses", body: body,
            options: automaticIdempotencyOptions(options)
        )
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
        let effectiveOptions = automaticIdempotencyOptions(options)
        let (bytes, response, recorder) = try await rawStreamRequestWithRecorder(
            method: "POST",
            path: "/responses",
            headers: ["accept": "text/event-stream"],
            body: bodyData,
            options: effectiveOptions
        )

        if !(200..<300).contains(response.statusCode) {
            let result = try await streamingError(
                bytes: bytes, response: response, recorder: recorder
            )
            recorder?.finish()
            throw result
        }

        return makeDictionarySSEEvents(bytes: bytes, recorder: recorder)
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
        return try await request(
            method: "POST", path: "/responses/input_tokens", body: body,
            options: automaticIdempotencyOptions(options)
        )
    }
}
