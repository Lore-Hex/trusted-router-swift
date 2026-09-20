import Foundation

// MARK: - Generic Wrappers

/// Typed collection returned by list endpoints.
public struct DataList<T: Codable & Sendable>: Codable, Sendable {
    /// Decoded values from the response data field.
    public var data: [T]
}

// MARK: - Metadata Models

/// Model identity, context limits, and routing capabilities.
public struct ModelInfo: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Wire object discriminator returned by the service.
    public var object: String?
    /// Creation time expressed as Unix seconds.
    public var created: Int?
    /// Organization that owns or publishes the model.
    public var ownedBy: String?
    /// Human-readable name or function name, as defined by the endpoint.
    public var name: String?
    /// Human-readable description.
    public var description: String?
    /// Maximum context length advertised for the model, in tokens.
    public var contextLength: Int?
    /// TrustedRouter-specific model metadata.
    public var trustedrouter: ModelTrustedRouterMetadata?

    /// Whether the model is advertised as having open weights.
    public var openWeights: Bool { trustedrouter?.openWeights ?? false }
    /// Whether a US provider is available for this model.
    public var usProviderAvailable: Bool { trustedrouter?.usProviderAvailable ?? false }
    /// Whether an EU-focused provider is available for this model.
    public var euFocusedProviderAvailable: Bool { trustedrouter?.euFocusedProviderAvailable ?? false }

    enum CodingKeys: String, CodingKey {
        case id, object, created, name, description, trustedrouter
        case ownedBy = "owned_by"
        case contextLength = "context_length"
    }
}

/// TrustedRouter-specific model availability and privacy metadata.
public struct ModelTrustedRouterMetadata: Codable, Sendable {
    /// Whether the model is advertised as having open weights.
    public var openWeights: Bool?
    /// Whether a US provider is available for this model.
    public var usProviderAvailable: Bool?
    /// Whether an EU-focused provider is available for this model.
    public var euFocusedProviderAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case openWeights = "open_weights"
        case usProviderAvailable = "us_provider_available"
        case euFocusedProviderAvailable = "eu_focused_provider_available"
    }
}

/// Typed provider info data returned by the service.
public struct ProviderInfo: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Human-readable name or function name, as defined by the endpoint.
    public var name: String?
}

/// Typed region info data returned by the service.
public struct RegionInfo: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Human-readable name or function name, as defined by the endpoint.
    public var name: String?
}

/// Typed credits response data returned by the service.
public struct CreditsResponse: Codable, Sendable {
    /// Available credit balance reported by the service.
    public var balance: Double
    /// Currency code used for the credit balance.
    public var currency: String?
}

// MARK: - Chat Models

/// Codable representation of arbitrary JSON retained by forward-compatible
/// response fields such as Responses output/usage and chat logprobs.
public enum JSONValue: Codable, Sendable, Equatable {
    /// A JSON null value.
    case null
    /// A JSON boolean value.
    case bool(Bool)
    /// A JSON integer value.
    case integer(Int)
    /// A JSON number value.
    case number(Double)
    /// A JSON string value.
    case string(String)
    /// An ordered collection of JSON values.
    case array([JSONValue])
    /// A JSON object keyed by field name.
    case object([String: JSONValue])

    /// Decodes this value from its wire representation.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let item = try? value.decode(Bool.self) {
            self = .bool(item)
        } else if let item = try? value.decode(Int.self) {
            self = .integer(item)
        } else if let item = try? value.decode(Double.self) {
            self = .number(item)
        } else if let item = try? value.decode(String.self) {
            self = .string(item)
        } else if let item = try? value.decode([JSONValue].self) {
            self = .array(item)
        } else {
            self = .object(try value.decode([String: JSONValue].self))
        }
    }

    /// Encodes this value using its wire field names.
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

/// Typed chat function call data returned by the service.
public struct ChatFunctionCall: Codable, Sendable, Equatable {
    /// Human-readable name or function name, as defined by the endpoint.
    public var name: String?
    /// JSON-encoded argument string for the function call.
    public var arguments: String?

    /// Creates a `ChatFunctionCall` with the supplied values.
    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

/// Typed chat tool call data returned by the service.
public struct ChatToolCall: Codable, Sendable, Equatable {
    /// Zero-based position in the response collection.
    public var index: Int?
    /// Identifier assigned by the service.
    public var id: String?
    /// Wire type discriminator.
    public var type: String?
    /// Function name and serialized arguments for this tool call.
    public var function: ChatFunctionCall?

    /// Creates a `ChatToolCall` with the supplied values.
    public init(
        index: Int? = nil,
        id: String? = nil,
        type: String? = nil,
        function: ChatFunctionCall? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

/// Typed chat completion chunk data returned by the service.
public struct ChatCompletionChunk: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String?
    /// Wire object discriminator returned by the service.
    public var object: String?
    /// Creation time expressed as Unix seconds.
    public var created: Int?
    /// Model identifier associated with the request or response.
    public var model: String?
    /// Provider fingerprint identifying the model configuration.
    public var systemFingerprint: String?
    /// Completion alternatives returned by the model.
    public var choices: [Choice]
    /// Token usage reported by the provider.
    public var usage: ChatCompletion.Usage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case systemFingerprint = "system_fingerprint"
    }

    /// Typed choice data within `ChatCompletionChunk`.
    public struct Choice: Codable, Sendable {
        /// Zero-based position in the response collection.
        public var index: Int?
        /// Incremental message fields carried by this streaming choice.
        public var delta: Delta?
        /// Provider termination reason for this completion.
        public var finishReason: String?
        /// Token log probabilities retained as arbitrary JSON.
        public var logprobs: JSONValue?

        enum CodingKeys: String, CodingKey {
            case index, delta, logprobs
            case finishReason = "finish_reason"
        }

        /// Typed delta data within `ChatCompletionChunk.Choice`.
        public struct Delta: Codable, Sendable {
            /// Message role, such as system, user, assistant, or tool.
            public var role: String?
            /// Message content returned by or sent to the model.
            public var content: String?
            /// Refusal explanation supplied by the model, when present.
            public var refusal: String?
            /// Reasoning text supplied by the provider, when present.
            public var reasoning: String?
            /// Provider-specific reasoning content, when present.
            public var reasoningContent: String?
            /// Tool calls requested by the model.
            public var toolCalls: [ChatToolCall]?
            /// Legacy function call supplied by the model.
            public var functionCall: ChatFunctionCall?

            enum CodingKeys: String, CodingKey {
                case role, content, refusal, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case functionCall = "function_call"
            }
        }
    }
}

/// Typed chat completion data returned by the service.
public struct ChatCompletion: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Wire object discriminator returned by the service.
    public var object: String
    /// Creation time expressed as Unix seconds.
    public var created: Int?
    /// Model identifier associated with the request or response.
    public var model: String?
    /// Provider fingerprint identifying the model configuration.
    public var systemFingerprint: String?
    /// Completion alternatives returned by the model.
    public var choices: [Choice]
    /// Token usage reported by the provider.
    public var usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case systemFingerprint = "system_fingerprint"
    }

    /// Typed choice data within `ChatCompletion`.
    public struct Choice: Codable, Sendable {
        /// Zero-based position in the response collection.
        public var index: Int
        /// Complete assistant message for this completion choice.
        public var message: Message
        /// Provider termination reason for this completion.
        public var finishReason: String?
        /// Token log probabilities retained as arbitrary JSON.
        public var logprobs: JSONValue?

        enum CodingKeys: String, CodingKey {
            case index, message, logprobs
            case finishReason = "finish_reason"
        }

        /// Typed message data within `ChatCompletion.Choice`.
        public struct Message: Codable, Sendable {
            /// Message role, such as system, user, assistant, or tool.
            public var role: String
            /// Message content returned by or sent to the model.
            public var content: String?
            /// Human-readable name or function name, as defined by the endpoint.
            public var name: String?
            /// Refusal explanation supplied by the model, when present.
            public var refusal: String?
            /// Reasoning text supplied by the provider, when present.
            public var reasoning: String?
            /// Provider-specific reasoning content, when present.
            public var reasoningContent: String?
            /// Tool calls requested by the model.
            public var toolCalls: [ChatToolCall]?
            /// Identifier of the tool call answered by this message.
            public var toolCallId: String?
            /// Legacy function call supplied by the model.
            public var functionCall: ChatFunctionCall?

            enum CodingKeys: String, CodingKey {
                case role, content, name, refusal, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case toolCallId = "tool_call_id"
                case functionCall = "function_call"
            }
        }
    }

    /// Typed usage data within `ChatCompletion`.
    public struct Usage: Codable, Sendable {
        /// Number of tokens consumed by the prompt.
        public var promptTokens: Int
        /// Number of generated completion tokens.
        public var completionTokens: Int
        /// Total token count reported by the service.
        public var totalTokens: Int
        /// Provider-specific breakdown of prompt tokens.
        public var promptTokensDetails: JSONValue?
        /// Provider-specific breakdown of generated tokens.
        public var completionTokensDetails: JSONValue?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case completionTokensDetails = "completion_tokens_details"
        }
    }
}

// MARK: - Other API Models

/// Typed embedding response data returned by the service.
public struct EmbeddingResponse: Codable, Sendable {
    /// Wire object discriminator returned by the service.
    public var object: String?
    /// Decoded values from the response data field.
    public var data: [Embedding]
    /// Model identifier associated with the request or response.
    public var model: String
    /// Token usage reported by the provider.
    public var usage: ChatCompletion.Usage?

    /// Typed embedding data within `EmbeddingResponse`.
    public struct Embedding: Codable, Sendable {
        /// Zero-based position in the response collection.
        public var index: Int
        /// Wire object discriminator returned by the service.
        public var object: String?
        /// Embedding vector returned by the model.
        public var embedding: [Double]
    }
}

/// Typed message response data returned by the service.
public struct MessageResponse: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Wire type discriminator.
    public var type: String?
    /// Message role, such as system, user, assistant, or tool.
    public var role: String
    /// Message content returned by or sent to the model.
    public var content: [Content]
    /// Model identifier associated with the request or response.
    public var model: String
    /// Provider reason for ending message generation.
    public var stopReason: String?
    /// Token usage reported by the provider.
    public var usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model
        case stopReason = "stop_reason"
        case usage
    }

    /// Typed content data within `MessageResponse`.
    public struct Content: Codable, Sendable {
        /// Wire type discriminator.
        public var type: String
        /// Text content of this message part.
        public var text: String?
    }

    /// Typed usage data within `MessageResponse`.
    public struct Usage: Codable, Sendable {
        /// Number of input tokens.
        public var inputTokens: Int
        /// Number of output tokens.
        public var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

/// Typed response object data returned by the service.
public struct ResponseObject: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Wire object discriminator returned by the service.
    public var object: String
    /// Creation timestamp returned by the service.
    public var createdAt: Int?
    /// Status reported by the service.
    public var status: String?
    /// Model identifier associated with the request or response.
    public var model: String?
    /// Response output items retained as JSON.
    public var output: [JSONValue]?
    /// Token usage reported by the provider.
    public var usage: JSONValue?
    /// Error details returned by the Responses API.
    public var error: JSONValue?
    /// Details explaining an incomplete response.
    public var incompleteDetails: JSONValue?
    /// Additional metadata returned by the service.
    public var metadata: [String: JSONValue]?
    /// Instructions associated with the response.
    public var instructions: JSONValue?
    /// Additional response details retained as JSON.
    public var details: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, object, status, model, output, usage, error, metadata, instructions, details
        case createdAt = "created_at"
        case incompleteDetails = "incomplete_details"
    }

    /// Decodes this value from its wire representation.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        object = try values.decode(String.self, forKey: .object)
        createdAt = try values.decodeIfPresent(Int.self, forKey: .createdAt)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        output = try values.decodeIfPresent([JSONValue].self, forKey: .output)
        usage = try values.decodeIfPresent(JSONValue.self, forKey: .usage)
        error = values.contains(.error)
            ? try values.decode(JSONValue.self, forKey: .error) : nil
        incompleteDetails = try values.decodeIfPresent(JSONValue.self, forKey: .incompleteDetails)
        metadata = try values.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        instructions = try values.decodeIfPresent(JSONValue.self, forKey: .instructions)
        details = try values.decodeIfPresent(JSONValue.self, forKey: .details)
    }

    /// Encodes this value using its wire field names.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(object, forKey: .object)
        try values.encodeIfPresent(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(status, forKey: .status)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(output, forKey: .output)
        try values.encodeIfPresent(usage, forKey: .usage)
        try values.encodeIfPresent(error, forKey: .error)
        try values.encodeIfPresent(incompleteDetails, forKey: .incompleteDetails)
        try values.encodeIfPresent(metadata, forKey: .metadata)
        try values.encodeIfPresent(instructions, forKey: .instructions)
        try values.encodeIfPresent(details, forKey: .details)
    }
}

/// Typed response input tokens data returned by the service.
public struct ResponseInputTokens: Codable, Sendable {
    /// Number of input tokens.
    public var inputTokens: Int
    /// Total token count reported by the service.
    public var totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Typed broadcast destination data returned by the service.
public struct BroadcastDestination: Codable, Sendable {
    /// Identifier assigned by the service.
    public var id: String
    /// Wire type discriminator.
    public var type: String
    /// Human-readable name or function name, as defined by the endpoint.
    public var name: String?
    /// Destination endpoint.
    public var endpoint: String?
    /// Whether delivery to this broadcast destination is enabled.
    public var enabled: Bool?
    /// Whether broadcast delivery includes request and response content.
    public var includeContent: Bool?
    /// HTTP method used for broadcast delivery.
    public var method: String?

    enum CodingKeys: String, CodingKey {
        case id, type, name, endpoint, enabled, method
        case includeContent = "include_content"
    }
}

/// Typed checkout response data returned by the service.
public struct CheckoutResponse: Codable, Sendable {
    /// URL returned by the service.
    public var url: String?
    /// Status reported by the service.
    public var status: String?
}

/// Typed empty response data returned by the service.
public struct EmptyResponse: Codable, Sendable {}

/// Typed auth session response data returned by the service.
public struct AuthSessionResponse: Codable, Sendable {
    /// Whether the current session is authenticated.
    public var authenticated: Bool
    /// User associated with the authenticated session.
    public var user: UserInfo?

    /// Typed user info data within `AuthSessionResponse`.
    public struct UserInfo: Codable, Sendable {
        /// Identifier assigned by the service.
        public var id: String
        /// Email address associated with the identity.
        public var email: String?
    }
}

/// Typed activity response data returned by the service.
public struct ActivityResponse: Codable, Sendable {
    /// Activity records returned by the service.
    public var activities: [Activity]

    /// Typed activity data within `ActivityResponse`.
    public struct Activity: Codable, Sendable {
        /// Identifier assigned by the service.
        public var id: String
        /// Creation timestamp returned by the service.
        public var createdAt: Int?
        /// Wire type discriminator.
        public var type: String?
        /// Additional metadata returned by the service.
        public var metadata: [String: String]?

        enum CodingKeys: String, CodingKey {
            case id, type, metadata
            case createdAt = "created_at"
        }
    }
}
