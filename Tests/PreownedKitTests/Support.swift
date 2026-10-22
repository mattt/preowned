import Foundation
import Hummingbird
import HummingbirdTesting
import Synchronization

@testable import PreownedKit

/// A chat service that returns canned results and records prompts.
final class FakeChatService: ChatService {
    let availability: ServiceAvailability
    let supportsImageInput: Bool
    let result: Result<ChatResult, OpenAIError>
    let events: [ChatStreamEvent]
    /// An error that the stream throws after `events`.
    let streamError: OpenAIError?
    private let prompts = Mutex<[ChatPrompt]>([])

    init(
        availability: ServiceAvailability = .available,
        supportsImageInput: Bool = false,
        result: Result<ChatResult, OpenAIError> = .success(
            ChatResult(content: "Hello!", usage: ChatUsage(promptTokens: 5, completionTokens: 2))
        ),
        events: [ChatStreamEvent] = [
            .delta("Hel"),
            .delta("lo!"),
            .finished(ChatStreamSummary(usage: ChatUsage(promptTokens: 5, completionTokens: 2))),
        ],
        streamError: OpenAIError? = nil
    ) {
        self.availability = availability
        self.supportsImageInput = supportsImageInput
        self.result = result
        self.events = events
        self.streamError = streamError
    }

    var lastPrompt: ChatPrompt? {
        prompts.withLock { $0.last }
    }

    func respond(to prompt: ChatPrompt) async throws -> ChatResult {
        prompts.withLock { $0.append(prompt) }
        return try result.get()
    }

    func streamResponse(to prompt: ChatPrompt) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        prompts.withLock { $0.append(prompt) }
        let (stream, continuation) = AsyncThrowingStream<ChatStreamEvent, any Error>.makeStream()
        for event in events {
            continuation.yield(event)
        }
        continuation.finish(throwing: streamError)
        return stream
    }
}

/// An embedding service that is available and returns zero vectors.
struct FakeEmbeddingService: EmbeddingService {
    var availability: ServiceAvailability = .available
    var dimensions: Int { 3 }

    func embed(_ inputs: [String]) async throws -> [[Float]] {
        inputs.map { _ in [0, 0, 0] }
    }
}

/// Runs a test against the router.
func withServer(
    _ services: ServiceRegistry,
    configuration: ServerConfiguration = ServerConfiguration(),
    _ test: @escaping @Sendable (any TestClientProtocol) async throws -> Void
) async throws {
    let app = Application(router: PreownedServer.router(services: services, configuration: configuration))
    try await app.test(.router, test)
}

extension TestClientProtocol {
    /// Posts a JSON body.
    func post(
        _ uri: String,
        json: String,
        headers: HTTPFields = [:],
        _ callback: @escaping (TestResponse) async throws -> Void = { _ in }
    ) async throws {
        var headers = headers
        headers[.contentType] = "application/json"
        try await execute(
            uri: uri, method: .post, headers: headers, body: ByteBuffer(string: json), testCallback: callback)
    }
}

extension TestResponse {
    /// The body as a string.
    var text: String {
        String(buffer: body)
    }

    /// Decodes the body as JSON.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(buffer: body))
    }

    /// Decodes the body as an OpenAI error body.
    var error: ErrorBody.Detail? {
        try? decode(ErrorBody.self).error
    }
}

/// A chat completion request body with one user message.
func chatBody(_ extra: String = "", content: String = "Hi") -> String {
    let separator = extra.isEmpty ? "" : ", "
    return #"{"messages": [{"role": "user", "content": "\#(content)"}]\#(separator)\#(extra)}"#
}
