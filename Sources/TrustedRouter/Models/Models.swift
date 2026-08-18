import Foundation

// MARK: - Generic Wrappers

public struct DataList<T: Codable & Sendable>: Codable, Sendable {
    public var data: [T]
}

// MARK: - Metadata Models

public struct ModelInfo: Codable, Sendable {
    public var id: String
    public var object: String?
    public var created: Int?
    public var ownedBy: String?
    public var name: String?
    public var description: String?
    public var contextLength: Int?
    public var trustedrouter: ModelTrustedRouterMetadata?

    public var openWeights: Bool { trustedrouter?.openWeights ?? false }
    public var usProviderAvailable: Bool { trustedrouter?.usProviderAvailable ?? false }
    public var euFocusedProviderAvailable: Bool { trustedrouter?.euFocusedProviderAvailable ?? false }
    
    enum CodingKeys: String, CodingKey {
        case id, object, created, name, description, trustedrouter
        case ownedBy = "owned_by"
        case contextLength = "context_length"
    }
}

public struct ModelTrustedRouterMetadata: Codable, Sendable {
    public var openWeights: Bool?
    public var usProviderAvailable: Bool?
    public var euFocusedProviderAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case openWeights = "open_weights"
        case usProviderAvailable = "us_provider_available"
        case euFocusedProviderAvailable = "eu_focused_provider_available"
    }
}

public struct ProviderInfo: Codable, Sendable {
    public var id: String
    public var name: String?
}

public struct RegionInfo: Codable, Sendable {
    public var id: String
    public var name: String?
}

public struct CreditsResponse: Codable, Sendable {
    public var balance: Double
    public var currency: String?
}

// MARK: - Chat Models

/// Codable representation of arbitrary JSON retained by forward-compatible
/// response fields such as Responses output/usage and chat logprobs.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([JSONValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

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

public struct ChatFunctionCall: Codable, Sendable, Equatable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatToolCall: Codable, Sendable, Equatable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: ChatFunctionCall?

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

public struct ChatCompletionChunk: Codable, Sendable {
    public var id: String?
    public var object: String?
    public var created: Int?
    public var model: String?
    public var systemFingerprint: String? = nil
    public var choices: [Choice]
    public var usage: ChatCompletion.Usage? = nil

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case systemFingerprint = "system_fingerprint"
    }
    
    public struct Choice: Codable, Sendable {
        public var index: Int?
        public var delta: Delta?
        public var finishReason: String?
        public var logprobs: JSONValue? = nil
        
        enum CodingKeys: String, CodingKey {
            case index, delta, logprobs
            case finishReason = "finish_reason"
        }
        
        public struct Delta: Codable, Sendable {
            public var role: String?
            public var content: String?
            public var refusal: String? = nil
            public var reasoning: String? = nil
            public var reasoningContent: String? = nil
            public var toolCalls: [ChatToolCall]? = nil
            public var functionCall: ChatFunctionCall? = nil

            enum CodingKeys: String, CodingKey {
                case role, content, refusal, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case functionCall = "function_call"
            }
        }
    }
}

public struct ChatCompletion: Codable, Sendable {
    public var id: String
    public var object: String
    public var created: Int?
    public var model: String?
    public var systemFingerprint: String? = nil
    public var choices: [Choice]
    public var usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, object, created, model, choices, usage
        case systemFingerprint = "system_fingerprint"
    }
    
    public struct Choice: Codable, Sendable {
        public var index: Int
        public var message: Message
        public var finishReason: String?
        public var logprobs: JSONValue? = nil
        
        enum CodingKeys: String, CodingKey {
            case index, message, logprobs
            case finishReason = "finish_reason"
        }
        
        public struct Message: Codable, Sendable {
            public var role: String
            public var content: String?
            public var name: String? = nil
            public var refusal: String? = nil
            public var reasoning: String? = nil
            public var reasoningContent: String? = nil
            public var toolCalls: [ChatToolCall]? = nil
            public var toolCallId: String? = nil
            public var functionCall: ChatFunctionCall? = nil

            enum CodingKeys: String, CodingKey {
                case role, content, name, refusal, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
                case toolCallId = "tool_call_id"
                case functionCall = "function_call"
            }
        }
    }
    
    public struct Usage: Codable, Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int
        public var promptTokensDetails: JSONValue? = nil
        public var completionTokensDetails: JSONValue? = nil
        
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

public struct EmbeddingResponse: Codable, Sendable {
    public var object: String?
    public var data: [Embedding]
    public var model: String
    public var usage: ChatCompletion.Usage?
    
    public struct Embedding: Codable, Sendable {
        public var index: Int
        public var object: String?
        public var embedding: [Double]
    }
}

public struct MessageResponse: Codable, Sendable {
    public var id: String
    public var type: String?
    public var role: String
    public var content: [Content]
    public var model: String
    public var stopReason: String?
    public var usage: Usage?
    
    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model
        case stopReason = "stop_reason"
        case usage
    }
    
    public struct Content: Codable, Sendable {
        public var type: String
        public var text: String?
    }
    
    public struct Usage: Codable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int
        
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

public struct ResponseObject: Codable, Sendable {
    public var id: String
    public var object: String
    public var createdAt: Int?
    public var status: String?
    public var model: String?
    public var output: [JSONValue]? = nil
    public var usage: JSONValue? = nil
    public var error: JSONValue? = nil
    public var incompleteDetails: JSONValue? = nil
    public var metadata: [String: JSONValue]? = nil
    public var instructions: JSONValue? = nil
    public var details: JSONValue? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, object, status, model, output, usage, error, metadata, instructions, details
        case createdAt = "created_at"
        case incompleteDetails = "incomplete_details"
    }

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

public struct ResponseInputTokens: Codable, Sendable {
    public var inputTokens: Int
    public var totalTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct BroadcastDestination: Codable, Sendable {
    public var id: String
    public var type: String
    public var name: String?
    public var endpoint: String?
    public var enabled: Bool?
    public var includeContent: Bool?
    public var method: String?
    
    enum CodingKeys: String, CodingKey {
        case id, type, name, endpoint, enabled, method
        case includeContent = "include_content"
    }
}

public struct CheckoutResponse: Codable, Sendable {
    public var url: String?
    public var status: String?
}

public struct EmptyResponse: Codable, Sendable {}

public struct AuthSessionResponse: Codable, Sendable {
    public var authenticated: Bool
    public var user: UserInfo?
    
    public struct UserInfo: Codable, Sendable {
        public var id: String
        public var email: String?
    }
}

public struct ActivityResponse: Codable, Sendable {
    public var activities: [Activity]
    
    public struct Activity: Codable, Sendable {
        public var id: String
        public var createdAt: Int?
        public var type: String?
        public var metadata: [String: String]?
        
        enum CodingKeys: String, CodingKey {
            case id, type, metadata
            case createdAt = "created_at"
        }
    }
}
