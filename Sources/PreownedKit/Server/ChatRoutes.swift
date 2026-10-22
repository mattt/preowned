import Foundation
import Hummingbird

/// `POST /v1/chat/completions`.
struct ChatRoutes {
    let services: ServiceRegistry
    let resolver: ModelResolver

    func register(on router: Router<BasicRequestContext>) {
        router.post("/v1/chat/completions") { request, _ in
            var request = request
            let body = try await request.decodeJSON(ChatCompletionRequest.self)
            return try await complete(body)
        }
    }

    private func complete(_ body: ChatCompletionRequest) async throws -> Response {
        let model = try resolver.resolve(body.model, for: .chat)
        let prompt = try ChatPromptBuilder.prompt(for: body)

        guard let service = services.chat else {
            throw OpenAIError.serviceUnavailable(ServiceRegistry.notImplementedReason)
        }
        if let reason = service.availability.reason {
            throw OpenAIError.serviceUnavailable(reason)
        }
        if prompt.containsImages, !service.supportsImageInput {
            throw OpenAIError.invalidRequest(
                "The model on this Mac does not accept images.",
                param: "messages",
                code: "unsupported_value"
            )
        }

        let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let created = Int(Date().timeIntervalSince1970)

        if body.stream == true {
            return try await stream(
                service.streamResponse(to: prompt),
                id: id,
                created: created,
                model: model,
                includeUsage: body.streamOptions?.includeUsage == true,
                waitsForFirstEvent: prompt.format == .text
            )
        }

        let result = try await service.respond(to: prompt)
        return try Response.json(
            ChatCompletion(
                id: id,
                created: created,
                model: model,
                choices: [
                    .init(
                        index: 0,
                        message: .init(content: result.content),
                        finishReason: result.finishReason.rawValue
                    )
                ],
                usage: ChatCompletionUsage(result.usage)
            )
        )
    }

    /// Streams events as OpenAI chunks.
    ///
    /// For free text, the route waits for the first event
    /// before it sends the headers,
    /// so an error at the start, such as an exceeded context window,
    /// gets its own status code.
    /// A `json_object` or `json_schema` response arrives as one event
    /// when the model finishes,
    /// so for those the route sends the headers and the role chunk at once,
    /// and clients see that the request is in progress.
    /// An error after the headers arrives as an `error` event,
    /// and the stream ends without `[DONE]`.
    private func stream(
        _ events: AsyncThrowingStream<ChatStreamEvent, any Error>,
        id: String,
        created: Int,
        model: String,
        includeUsage: Bool,
        waitsForFirstEvent: Bool
    ) async throws -> Response {
        let iterator = EventIterator(events)
        let first: ChatStreamEvent?? = waitsForFirstEvent ? .some(try await iterator.next()) : nil

        @Sendable func chunk(
            _ delta: ChatCompletionChunk.Delta,
            finishReason: String? = nil
        ) -> ChatCompletionChunk {
            ChatCompletionChunk(
                id: id,
                created: created,
                model: model,
                choices: [.init(delta: delta, finishReason: finishReason)]
            )
        }

        let body = ResponseBody { writer in
            try await writer.write(
                ServerSentEvents.event(chunk(.init(role: "assistant", content: "")))
            )

            var pending = first
            while true {
                let event: ChatStreamEvent?
                if let ready = pending {
                    event = ready
                    pending = nil
                } else {
                    do {
                        event = try await iterator.next()
                    } catch {
                        let openAIError = error as? OpenAIError ?? .server()
                        try await writer.write(ServerSentEvents.event(openAIError.body))
                        try await writer.finish(nil)
                        return
                    }
                }
                guard let current = event else { break }
                switch current {
                case .delta(let text):
                    try await writer.write(ServerSentEvents.event(chunk(.init(content: text))))
                case .finished(let summary):
                    try await writer.write(
                        ServerSentEvents.event(chunk(.init(), finishReason: summary.finishReason.rawValue))
                    )
                    if includeUsage {
                        let usageChunk = ChatCompletionChunk(
                            id: id,
                            created: created,
                            model: model,
                            choices: [],
                            usage: ChatCompletionUsage(summary.usage)
                        )
                        try await writer.write(ServerSentEvents.event(usageChunk))
                    }
                }
            }

            try await writer.write(ServerSentEvents.done)
            try await writer.finish(nil)
        }

        return Response(status: .ok, headers: ServerSentEvents.headers, body: body)
    }
}

/// An iterator that the route and the response body share.
///
/// Only one task uses the iterator at a time:
/// the route reads the first event,
/// and the response body reads the rest after the route returns.
private final class EventIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<ChatStreamEvent, any Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<ChatStreamEvent, any Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> ChatStreamEvent? {
        try await iterator.next()
    }
}

extension ChatCompletionUsage {
    init(_ usage: ChatUsage) {
        self.init(promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
    }
}
