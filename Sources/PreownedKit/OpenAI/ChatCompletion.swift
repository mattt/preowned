import Foundation

// MARK: - Request

/// The body of `POST /v1/chat/completions`.
///
/// The type decodes the fields that preowned uses or rejects.
/// The decoder ignores other fields,
/// such as `top_p`, `stop`, `seed`, and `user`.
public struct ChatCompletionRequest: Decodable, Sendable, Equatable {
    public var model: String?
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    public var maxCompletionTokens: Int?
    public var n: Int?
    public var stream: Bool?
    public var streamOptions: StreamOptions?
    public var responseFormat: ResponseFormat?
    public var tools: [JSONValue]?
    public var toolChoice: JSONValue?
    public var functions: [JSONValue]?
    public var functionCall: JSONValue?

    public init(
        model: String? = nil,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        maxCompletionTokens: Int? = nil,
        n: Int? = nil,
        stream: Bool? = nil,
        streamOptions: StreamOptions? = nil,
        responseFormat: ResponseFormat? = nil,
        tools: [JSONValue]? = nil,
        toolChoice: JSONValue? = nil,
        functions: [JSONValue]? = nil,
        functionCall: JSONValue? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.n = n
        self.stream = stream
        self.streamOptions = streamOptions
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
        self.functions = functions
        self.functionCall = functionCall
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case n
        case stream
        case streamOptions = "stream_options"
        case responseFormat = "response_format"
        case tools
        case toolChoice = "tool_choice"
        case functions
        case functionCall = "function_call"
    }

    /// The `stream_options` object.
    public struct StreamOptions: Codable, Sendable, Equatable {
        public var includeUsage: Bool?

        public init(includeUsage: Bool? = nil) {
            self.includeUsage = includeUsage
        }

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    /// The `response_format` object.
    public enum ResponseFormat: Decodable, Sendable, Equatable {
        case text
        case jsonObject
        case jsonSchema(JSONSchemaFormat)
        case unknown(String)

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text
            case "json_object":
                self = .jsonObject
            case "json_schema":
                self = .jsonSchema(try container.decode(JSONSchemaFormat.self, forKey: .jsonSchema))
            default:
                self = .unknown(type)
            }
        }
    }

    /// The `json_schema` member of a `response_format` object.
    public struct JSONSchemaFormat: Codable, Sendable, Equatable {
        public var name: String
        public var description: String?
        public var schema: JSONValue?
        public var strict: Bool?

        public init(
            name: String,
            description: String? = nil,
            schema: JSONValue? = nil,
            strict: Bool? = nil
        ) {
            self.name = name
            self.description = description
            self.schema = schema
            self.strict = strict
        }
    }
}

/// A message in a chat completion request.
public struct ChatMessage: Decodable, Sendable, Equatable {
    public var role: String
    public var content: Content?
    public var name: String?
    public var toolCalls: JSONValue?
    public var toolCallID: String?

    public init(role: String, content: Content?, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    /// Message content: a string or an array of content parts.
    public enum Content: Decodable, Sendable, Equatable {
        case text(String)
        case parts([ContentPart])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .parts(try container.decode([ContentPart].self))
            }
        }
    }

    /// A content part, such as `{"type": "text", "text": "..."}`.
    public enum ContentPart: Decodable, Sendable, Equatable {
        case text(String)
        case imageURL(String)
        case unsupported(String)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
            case refusal
        }

        struct ImageURL: Decodable {
            var url: String
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(try container.decode(String.self, forKey: .text))
            case "image_url":
                self = .imageURL(try container.decode(ImageURL.self, forKey: .imageURL).url)
            case "refusal":
                self = .text(try container.decode(String.self, forKey: .refusal))
            default:
                self = .unsupported(type)
            }
        }
    }
}

// MARK: - Response

/// A token count report, as in OpenAI's `usage` object.
public struct ChatCompletionUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = promptTokens + completionTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// The response of a chat completion request without streaming.
public struct ChatCompletion: Codable, Sendable, Equatable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]
    public var usage: ChatCompletionUsage

    public init(
        id: String,
        created: Int,
        model: String,
        choices: [Choice],
        usage: ChatCompletionUsage
    ) {
        self.id = id
        self.object = "chat.completion"
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    public struct Choice: Codable, Sendable, Equatable {
        public var index: Int
        public var message: Message
        public var finishReason: String

        public init(index: Int, message: Message, finishReason: String) {
            self.index = index
            self.message = message
            self.finishReason = finishReason
        }

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
            case logprobs
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            message = try container.decode(Message.self, forKey: .message)
            finishReason = try container.decode(String.self, forKey: .finishReason)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(message, forKey: .message)
            try container.encode(finishReason, forKey: .finishReason)
            try container.encodeNil(forKey: .logprobs)
        }
    }

    public struct Message: Codable, Sendable, Equatable {
        public var role: String
        public var content: String

        public init(role: String = "assistant", content: String) {
            self.role = role
            self.content = content
        }

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case refusal
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)
            content = try container.decode(String.self, forKey: .content)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encodeNil(forKey: .refusal)
        }
    }
}

/// A chunk of a streaming chat completion,
/// sent as one server-sent event.
public struct ChatCompletionChunk: Codable, Sendable, Equatable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]
    public var usage: ChatCompletionUsage?

    public init(
        id: String,
        created: Int,
        model: String,
        choices: [Choice],
        usage: ChatCompletionUsage? = nil
    ) {
        self.id = id
        self.object = "chat.completion.chunk"
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    public struct Choice: Codable, Sendable, Equatable {
        public var index: Int
        public var delta: Delta
        public var finishReason: String?

        public init(index: Int = 0, delta: Delta, finishReason: String? = nil) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
            case logprobs
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            delta = try container.decode(Delta.self, forKey: .delta)
            finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        }

        // OpenAI sends `"finish_reason": null` until the last chunk.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(delta, forKey: .delta)
            try container.encode(finishReason, forKey: .finishReason)
            try container.encodeNil(forKey: .logprobs)
        }
    }

    public struct Delta: Codable, Sendable, Equatable {
        public var role: String?
        public var content: String?

        public init(role: String? = nil, content: String? = nil) {
            self.role = role
            self.content = content
        }
    }
}
