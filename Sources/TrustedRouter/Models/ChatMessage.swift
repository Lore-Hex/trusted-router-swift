import Foundation

/// Strongly-typed chat message. Use this with the `[ChatMessage]` overloads
/// of `chatCompletions(...)` / `chatCompletionsChunks(...)` when you don't
/// need to pass tool-call fields. For tool-call interop, fall back to the
/// `[[String: Any]]` overload.
public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var name: String?
    public var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallId = "tool_call_id"
    }

    public init(role: String, content: String? = nil, name: String? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
    }

    /// Convenience constructor for a plain user message.
    public static func user(_ content: String) -> ChatMessage {
        .init(role: "user", content: content)
    }
    /// Convenience constructor for a plain assistant message.
    public static func assistant(_ content: String) -> ChatMessage {
        .init(role: "assistant", content: content)
    }
    /// Convenience constructor for the system prompt.
    public static func system(_ content: String) -> ChatMessage {
        .init(role: "system", content: content)
    }
    /// Convenience constructor for a tool-result message (Chat Completions style).
    public static func tool(callId: String, content: String) -> ChatMessage {
        .init(role: "tool", content: content, toolCallId: callId)
    }
}
