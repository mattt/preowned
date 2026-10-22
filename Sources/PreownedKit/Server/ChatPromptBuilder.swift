import Foundation

/// Converts a chat completion request to a ``ChatPrompt``.
///
/// System and developer messages become instructions.
/// The last message must come from the user and becomes the prompt;
/// the user and assistant messages before it become the history.
public enum ChatPromptBuilder {
    /// The instruction for `response_format` `json_object`.
    ///
    /// Foundation Models has no free-form JSON mode,
    /// so the server asks for JSON in the instructions
    /// and removes a Markdown code fence from the response.
    public static let jsonObjectInstruction =
        "Respond with one valid JSON object and nothing else."

    /// Validates a request and converts it to a prompt.
    public static func prompt(for request: ChatCompletionRequest) throws(OpenAIError) -> ChatPrompt {
        if request.tools?.isEmpty == false || request.functions?.isEmpty == false {
            throw .invalidRequest(
                "Tool calling is not supported yet. Remove `tools` and `functions` from the request.",
                param: request.tools != nil ? "tools" : "functions",
                code: "unsupported_parameter"
            )
        }
        if let n = request.n, n != 1 {
            throw .invalidRequest(
                "Only one choice is supported. Set `n` to 1 or leave it out.",
                param: "n",
                code: "unsupported_value"
            )
        }
        if let temperature = request.temperature, !(0...2).contains(temperature) {
            throw .invalidRequest(
                "`temperature` must be between 0 and 2.",
                param: "temperature",
                code: "invalid_value"
            )
        }

        let maximumTokens = request.maxCompletionTokens ?? request.maxTokens
        if let maximumTokens, maximumTokens < 1 {
            throw .invalidRequest(
                "The maximum number of tokens must be at least 1.",
                param: request.maxCompletionTokens != nil ? "max_completion_tokens" : "max_tokens",
                code: "invalid_value"
            )
        }

        let format = try outputFormat(for: request.responseFormat)

        var instructions: [String] = []
        var turns: [ChatTurn] = []
        for (index, message) in request.messages.enumerated() {
            let param = "messages[\(index)]"
            switch message.role {
            case "system", "developer":
                let parts = try parts(of: message.content, param: param)
                let text = try textOnly(parts, param: param)
                if !text.isEmpty { instructions.append(text) }
            case "user":
                turns.append(ChatTurn(role: .user, parts: try parts(of: message.content, param: param)))
            case "assistant":
                if message.toolCalls != nil {
                    throw .invalidRequest(
                        "Tool calls are not supported yet.",
                        param: "\(param).tool_calls",
                        code: "unsupported_parameter"
                    )
                }
                let parts = try parts(of: message.content, param: param)
                let text = try textOnly(parts, param: param)
                turns.append(ChatTurn(role: .assistant, parts: [.text(text)]))
            case "tool", "function":
                throw .invalidRequest(
                    "Tool messages are not supported yet.",
                    param: "\(param).role",
                    code: "unsupported_value"
                )
            default:
                throw .invalidRequest(
                    "Invalid role `\(message.role)`.",
                    param: "\(param).role",
                    code: "invalid_value"
                )
            }
        }

        guard let last = turns.last, last.role == .user else {
            throw .invalidRequest(
                "The last message, other than system and developer messages, must have the role `user`.",
                param: "messages"
            )
        }

        if format == .jsonObject {
            instructions.append(jsonObjectInstruction)
        }

        return ChatPrompt(
            instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
            history: Array(turns.dropLast()),
            prompt: last.parts,
            options: ChatOptions(temperature: request.temperature, maximumResponseTokens: maximumTokens),
            format: format
        )
    }

    // MARK: -

    private static func outputFormat(
        for responseFormat: ChatCompletionRequest.ResponseFormat?
    ) throws(OpenAIError) -> ChatOutputFormat {
        switch responseFormat {
        case nil, .text:
            return .text
        case .jsonObject:
            return .jsonObject
        case .jsonSchema(let format):
            guard let schema = format.schema else {
                throw .invalidRequest(
                    "`response_format.json_schema.schema` is required.",
                    param: "response_format"
                )
            }
            let result = try JSONSchemaParser().parse(schema)
            return .jsonSchema(name: format.name, schema: result.root, definitions: result.definitions)
        case .unknown(let type):
            throw .invalidRequest(
                "Invalid `response_format` type `\(type)`. Use `text`, `json_object`, or `json_schema`.",
                param: "response_format.type",
                code: "invalid_value"
            )
        }
    }

    private static func parts(
        of content: ChatMessage.Content?,
        param: String
    ) throws(OpenAIError) -> [ChatPart] {
        switch content {
        case nil:
            return []
        case .text(let text):
            return [.text(text)]
        case .parts(let parts):
            var result: [ChatPart] = []
            for (index, part) in parts.enumerated() {
                switch part {
                case .text(let text):
                    result.append(.text(text))
                case .imageURL(let url):
                    result.append(.image(try imageData(from: url, param: "\(param).content[\(index)]")))
                case .unsupported(let type):
                    throw .invalidRequest(
                        "The content part type `\(type)` is not supported.",
                        param: "\(param).content[\(index)].type",
                        code: "unsupported_value"
                    )
                }
            }
            return result
        }
    }

    private static func textOnly(_ parts: [ChatPart], param: String) throws(OpenAIError) -> String {
        var texts: [String] = []
        for part in parts {
            guard let text = part.text else {
                throw .invalidRequest(
                    "Images are supported only in user messages.",
                    param: "\(param).content"
                )
            }
            texts.append(text)
        }
        return texts.joined(separator: "\n")
    }

    /// Decodes a base64 `data:` URL.
    ///
    /// The server makes no network requests for content,
    /// so it rejects `http` and `https` image URLs.
    static func imageData(from url: String, param: String) throws(OpenAIError) -> Data {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else {
            throw .invalidRequest(
                "Only base64 `data:` URLs are supported for images.",
                param: "\(param).image_url.url",
                code: "unsupported_value"
            )
        }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasPrefix("image/"), header.hasSuffix(";base64"),
            let data = Data(base64Encoded: String(url[url.index(after: comma)...]))
        else {
            throw .invalidRequest(
                "The image must be a base64 `data:image/...;base64,` URL.",
                param: "\(param).image_url.url",
                code: "invalid_value"
            )
        }
        return data
    }
}
