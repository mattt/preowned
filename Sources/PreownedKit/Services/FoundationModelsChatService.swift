import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// A chat service backed by the on-device Foundation Models model.
///
/// Each request gets a new `LanguageModelSession`
/// whose transcript holds the instructions and the earlier turns,
/// so requests don't share state.
///
/// On macOS 27 and later,
/// usage reports the model's token counts,
/// and prompts can include images if the model supports vision.
/// On macOS 26, usage is an estimate of one token for every four characters.
public struct FoundationModelsChatService: ChatService {
    public init() {}

    private var model: SystemLanguageModel { .default }

    public var availability: ServiceAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(reason: "This Mac is not eligible for Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(
                    reason: "Apple Intelligence is turned off. Turn it on in System Settings."
                )
            case .modelNotReady:
                return .unavailable(
                    reason: "The model is not ready. It may still be downloading."
                )
            @unknown default:
                return .unavailable(reason: "Foundation Models is unavailable.")
            }
        }
    }

    public var supportsImageInput: Bool {
        if #available(macOS 27.0, *) {
            return model.capabilities.contains(.vision)
        }
        return false
    }

    public func respond(to prompt: ChatPrompt) async throws -> ChatResult {
        try requireAvailable()
        let request = try PreparedRequest(prompt, model: model)
        do {
            if let schema = request.schema {
                let response = try await request.session.respond(
                    to: request.prompt,
                    schema: schema,
                    options: request.options
                )
                let content = response.rawContent.jsonString
                return result(content: content, usage: usage(of: response), prompt: prompt)
            } else {
                let response = try await request.session.respond(
                    to: request.prompt,
                    options: request.options
                )
                var content = response.content
                if prompt.format == .jsonObject {
                    content = Self.removingCodeFence(from: content)
                }
                return result(content: content, usage: usage(of: response), prompt: prompt)
            }
        } catch {
            throw Self.openAIError(for: error)
        }
    }

    public func streamResponse(
        to prompt: ChatPrompt
    ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try requireAvailable()
                    let request = try PreparedRequest(prompt, model: model)
                    var usage: ChatUsage?
                    let content: String

                    if let schema = request.schema {
                        // Partial JSON snapshots don't extend each other,
                        // so structured output arrives as one delta at the end.
                        var last: GeneratedContent?
                        let stream = request.session.streamResponse(
                            to: request.prompt,
                            schema: schema,
                            options: request.options
                        )
                        for try await snapshot in stream {
                            last = snapshot.rawContent
                            if #available(macOS 27.0, *) {
                                usage = ChatUsage(snapshot.usage)
                            }
                        }
                        content = last?.jsonString ?? ""
                        if !content.isEmpty {
                            continuation.yield(.delta(content))
                        }
                    } else {
                        var differ = SnapshotDiffer()
                        let stream = request.session.streamResponse(
                            to: request.prompt,
                            options: request.options
                        )
                        for try await snapshot in stream {
                            if let delta = differ.delta(for: snapshot.content) {
                                continuation.yield(.delta(delta))
                            }
                            if #available(macOS 27.0, *) {
                                usage = ChatUsage(snapshot.usage)
                            }
                        }
                        content = differ.emitted
                    }

                    let final = result(
                        content: content,
                        usage: usage ?? Self.estimatedUsage(prompt: prompt, content: content),
                        prompt: prompt
                    )
                    continuation.yield(
                        .finished(ChatStreamSummary(finishReason: final.finishReason, usage: final.usage))
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.openAIError(for: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: -

    private func requireAvailable() throws {
        if let reason = availability.reason {
            throw OpenAIError.serviceUnavailable(reason)
        }
    }

    private func usage<Content>(of response: LanguageModelSession.Response<Content>) -> ChatUsage? {
        if #available(macOS 27.0, *) {
            return ChatUsage(response.usage)
        }
        return nil
    }

    private func result(content: String, usage: ChatUsage?, prompt: ChatPrompt) -> ChatResult {
        let usage = usage ?? Self.estimatedUsage(prompt: prompt, content: content)
        var finishReason = ChatFinishReason.stop
        if let limit = prompt.options.maximumResponseTokens,
            !usage.isEstimated,
            usage.completionTokens >= limit
        {
            finishReason = .length
        }
        return ChatResult(content: content, finishReason: finishReason, usage: usage)
    }

    /// Estimates token counts at one token for every four characters,
    /// for systems that don't report counts.
    static func estimatedUsage(prompt: ChatPrompt, content: String) -> ChatUsage {
        func estimate(_ text: String) -> Int {
            (text.count + 3) / 4
        }
        let promptText =
            ([prompt.instructions ?? ""]
            + prompt.history.flatMap(\.parts).compactMap(\.text)
            + prompt.prompt.compactMap(\.text))
            .joined(separator: "\n")
        return ChatUsage(
            promptTokens: estimate(promptText),
            completionTokens: estimate(content),
            isEstimated: true
        )
    }

    /// Removes a Markdown code fence around a JSON response.
    static func removingCodeFence(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else {
            return trimmed
        }
        var body = trimmed.dropFirst(3).dropLast(3)
        if let newline = body.firstIndex(of: "\n") {
            // Drop a language tag, such as `json`, after the opening fence.
            let tag = body[..<newline].trimmingCharacters(in: .whitespaces)
            if tag.allSatisfy(\.isLetter) {
                body = body[body.index(after: newline)...]
            }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Request preparation

/// A session, a prompt, and options built from a ``ChatPrompt``.
private struct PreparedRequest {
    let session: LanguageModelSession
    let prompt: Prompt
    let options: GenerationOptions
    let schema: GenerationSchema?

    init(_ chatPrompt: ChatPrompt, model: SystemLanguageModel) throws {
        var entries: [Transcript.Entry] = []
        if let instructions = chatPrompt.instructions {
            entries.append(
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: instructions))],
                        toolDefinitions: []
                    )
                )
            )
        }
        for turn in chatPrompt.history {
            let segments = try turn.parts.map(Self.segment(for:))
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }

        self.session = LanguageModelSession(
            model: model,
            tools: [],
            transcript: Transcript(entries: entries)
        )
        self.prompt = try Self.prompt(for: chatPrompt.prompt)
        self.options = GenerationOptions(
            temperature: chatPrompt.options.temperature,
            maximumResponseTokens: chatPrompt.options.maximumResponseTokens
        )

        switch chatPrompt.format {
        case .text, .jsonObject:
            self.schema = nil
        case .jsonSchema(let name, let root, let definitions):
            do {
                self.schema = try GenerationSchemaBuilder.schema(
                    name: name,
                    root: root,
                    definitions: definitions
                )
            } catch let error as OpenAIError {
                throw error
            } catch {
                throw OpenAIError.invalidRequest(
                    "The JSON Schema could not be converted: \(error.localizedDescription)",
                    param: "response_format"
                )
            }
        }
    }

    private static func segment(for part: ChatPart) throws -> Transcript.Segment {
        switch part {
        case .text(let text):
            return .text(Transcript.TextSegment(content: text))
        case .image(let data):
            guard #available(macOS 27.0, *) else { throw imageInputUnsupported }
            let attachment = Transcript.ImageAttachment(try cgImage(from: data))
            return .attachment(Transcript.AttachmentSegment(content: .image(attachment)))
        }
    }

    private static func prompt(for parts: [ChatPart]) throws -> Prompt {
        let texts = parts.compactMap(\.text)
        if texts.count == parts.count {
            return Prompt(texts.joined(separator: "\n"))
        }
        guard #available(macOS 27.0, *) else { throw imageInputUnsupported }
        var prompts: [Prompt] = []
        for part in parts {
            switch part {
            case .text(let text):
                prompts.append(Prompt(text))
            case .image(let data):
                prompts.append(Prompt(Attachment(try cgImage(from: data))))
            }
        }
        return Prompt(prompts)
    }

    private static var imageInputUnsupported: OpenAIError {
        .invalidRequest(
            "Image input requires macOS 27 or later.",
            param: "messages",
            code: "unsupported_value"
        )
    }

    private static func cgImage(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OpenAIError.invalidRequest(
                "An image could not be decoded. Use PNG, JPEG, HEIC, or another format that ImageIO reads.",
                param: "messages",
                code: "invalid_value"
            )
        }
        return image
    }
}

// MARK: - Usage

extension ChatUsage {
    @available(macOS 27.0, *)
    init(_ usage: LanguageModelSession.Usage) {
        self.init(
            promptTokens: usage.input.totalTokenCount,
            completionTokens: usage.output.totalTokenCount
        )
    }
}

// MARK: - Errors

extension FoundationModelsChatService {
    /// Converts a Foundation Models error to an OpenAI error.
    ///
    /// An unavailable model gives 503,
    /// a guardrail violation or refusal gives 400 `content_policy_violation`,
    /// and an exceeded context window gives 400 `context_length_exceeded`.
    /// Other errors pass through, and the server reports them as 500.
    static func openAIError(for error: any Error) -> any Error {
        if error is OpenAIError || error is CancellationError {
            return error
        }

        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                return openAIError(for: error)
            }
            if let error = error as? SystemLanguageModel.Error {
                return OpenAIError.serviceUnavailable(
                    error.errorDescription ?? "The model's assets are unavailable."
                )
            }
            if let error = error as? LanguageModelSession.Error {
                return OpenAIError.rateLimited(
                    error.errorDescription ?? "The model is busy with another request."
                )
            }
        }

        if let error = error as? LanguageModelSession.GenerationError {
            return openAIError(for: error)
        }

        if let error = error as? GenerationSchema.SchemaError {
            return OpenAIError.invalidRequest(
                "The JSON Schema could not be converted: \(error.localizedDescription)",
                param: "response_format"
            )
        }

        return error
    }

    @available(macOS 27.0, *)
    private static func openAIError(for error: LanguageModelError) -> OpenAIError {
        let message = error.errorDescription ?? String(describing: error)
        switch error {
        case .contextSizeExceeded(let context):
            return .contextLengthExceeded(
                "This model's maximum context length is \(context.contextSize) tokens. "
                    + "However, your messages resulted in \(context.tokenCount) tokens."
            )
        case .guardrailViolation:
            return .contentPolicyViolation(
                "The request or response was blocked by the model's safety guardrails."
            )
        case .refusal:
            return .contentPolicyViolation("The model refused to respond.")
        case .rateLimited:
            return .rateLimited(message)
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
            return .invalidRequest(message, code: "unsupported_value")
        case .unsupportedLanguageOrLocale:
            return .invalidRequest(message, param: "messages", code: "unsupported_language")
        case .timeout:
            return OpenAIError(status: .gatewayTimeout, message: message, type: "server_error", code: "timeout")
        @unknown default:
            return .server(message)
        }
    }

    private static func openAIError(for error: LanguageModelSession.GenerationError) -> any Error {
        let message = error.errorDescription ?? String(describing: error)
        switch error {
        case .exceededContextWindowSize:
            return OpenAIError.contextLengthExceeded(
                "The messages exceed the model's context window. Shorten the conversation."
            )
        case .guardrailViolation:
            return OpenAIError.contentPolicyViolation(
                "The request or response was blocked by the model's safety guardrails."
            )
        case .refusal:
            return OpenAIError.contentPolicyViolation("The model refused to respond.")
        case .assetsUnavailable:
            return OpenAIError.serviceUnavailable(message)
        case .rateLimited, .concurrentRequests:
            return OpenAIError.rateLimited(message)
        case .unsupportedGuide:
            return OpenAIError.invalidRequest(message, param: "response_format", code: "unsupported_value")
        case .unsupportedLanguageOrLocale:
            return OpenAIError.invalidRequest(message, param: "messages", code: "unsupported_language")
        case .decodingFailure:
            return OpenAIError.server(message)
        @unknown default:
            return error
        }
    }
}
