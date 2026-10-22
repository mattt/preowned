import Foundation

/// A service that generates chat completions.
///
/// The server converts OpenAI messages to a ``ChatPrompt``
/// and converts the result back,
/// so an implementation sees no wire types.
public protocol ChatService: Sendable {
    /// Whether the service can handle requests now.
    var availability: ServiceAvailability { get }

    /// Whether the model accepts images in a prompt.
    var supportsImageInput: Bool { get }

    /// Generates a complete response.
    ///
    /// Throw ``OpenAIError`` for failures that clients should see
    /// with a specific status and code.
    func respond(to prompt: ChatPrompt) async throws -> ChatResult

    /// Generates a response as a sequence of content deltas,
    /// followed by one ``ChatStreamEvent/finished(_:)`` event.
    func streamResponse(to prompt: ChatPrompt) -> AsyncThrowingStream<ChatStreamEvent, any Error>
}

/// A conversation, converted from OpenAI messages.
public struct ChatPrompt: Sendable, Equatable {
    /// The text of the system and developer messages, in order.
    public var instructions: String?

    /// The turns before the last user message.
    public var history: [ChatTurn]

    /// The content of the last user message.
    public var prompt: [ChatPart]

    /// Sampling and length options.
    public var options: ChatOptions

    /// The form that the response must take.
    public var format: ChatOutputFormat

    public init(
        instructions: String? = nil,
        history: [ChatTurn] = [],
        prompt: [ChatPart],
        options: ChatOptions = ChatOptions(),
        format: ChatOutputFormat = .text
    ) {
        self.instructions = instructions
        self.history = history
        self.prompt = prompt
        self.options = options
        self.format = format
    }

    /// Whether any part of the conversation is an image.
    public var containsImages: Bool {
        (history.flatMap(\.parts) + prompt).contains {
            if case .image = $0 { return true }
            return false
        }
    }
}

/// A turn in a conversation.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public var role: Role
    public var parts: [ChatPart]

    public init(role: Role, parts: [ChatPart]) {
        self.role = role
        self.parts = parts
    }
}

/// A part of a message.
public enum ChatPart: Sendable, Equatable {
    case text(String)
    /// Encoded image data, such as PNG or JPEG.
    case image(Data)

    /// The text of the part, if it is text.
    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

/// Generation options for a chat completion.
public struct ChatOptions: Sendable, Equatable {
    public var temperature: Double?
    public var maximumResponseTokens: Int?

    public init(temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}

/// The form that a chat response must take.
public enum ChatOutputFormat: Sendable, Equatable {
    /// Free text.
    case text
    /// A JSON object without a fixed schema.
    case jsonObject
    /// JSON that matches a schema.
    case jsonSchema(name: String, schema: SchemaNode, definitions: [String: SchemaNode])
}

/// Why the model stopped generating.
public enum ChatFinishReason: String, Sendable, Equatable {
    case stop
    case length
}

/// Token counts for a chat completion.
public struct ChatUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// Whether the counts are estimates instead of counts from the model.
    public var isEstimated: Bool

    public init(promptTokens: Int, completionTokens: Int, isEstimated: Bool = false) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.isEstimated = isEstimated
    }
}

/// The result of a chat completion.
public struct ChatResult: Sendable, Equatable {
    public var content: String
    public var finishReason: ChatFinishReason
    public var usage: ChatUsage

    public init(content: String, finishReason: ChatFinishReason = .stop, usage: ChatUsage) {
        self.content = content
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// An event in a streaming chat completion.
public enum ChatStreamEvent: Sendable, Equatable {
    /// New content to append to the earlier content.
    case delta(String)
    /// The end of the response.
    case finished(ChatStreamSummary)
}

/// The final state of a streaming chat completion.
public struct ChatStreamSummary: Sendable, Equatable {
    public var finishReason: ChatFinishReason
    public var usage: ChatUsage

    public init(finishReason: ChatFinishReason = .stop, usage: ChatUsage) {
        self.finishReason = finishReason
        self.usage = usage
    }
}
