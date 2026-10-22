import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PreownedKit

@Suite("POST /v1/chat/completions")
struct ChatRoutesTests {
    @Test("A completion reports the canonical model ID and usage")
    func completion() async throws {
        let chat = FakeChatService()
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: chatBody(#""model": "gpt-4o""#)) { response in
                #expect(response.status == .ok)
                let completion = try response.decode(ChatCompletion.self)
                #expect(completion.object == "chat.completion")
                #expect(completion.id.hasPrefix("chatcmpl-"))
                #expect(completion.model == "apple-foundation-model")
                #expect(completion.choices.count == 1)
                #expect(completion.choices[0].message == .init(role: "assistant", content: "Hello!"))
                #expect(completion.choices[0].finishReason == "stop")
                #expect(completion.usage == ChatCompletionUsage(promptTokens: 5, completionTokens: 2))
                #expect(response.text.contains(#""refusal":null"#))
                #expect(response.text.contains(#""logprobs":null"#))
            }
        }
        #expect(chat.lastPrompt?.prompt == [.text("Hi")])
    }

    @Test("Messages become instructions, history, and a prompt with options")
    func promptConversion() async throws {
        let chat = FakeChatService()
        let body = #"""
            {
              "model": "apple-foundation-model",
              "temperature": 0.5,
              "max_completion_tokens": 64,
              "messages": [
                {"role": "system", "content": "Be brief."},
                {"role": "user", "content": "Hi"},
                {"role": "assistant", "content": "Hello."},
                {"role": "user", "content": [{"type": "text", "text": "How are you?"}]}
              ]
            }
            """#
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: body) { response in
                #expect(response.status == .ok)
            }
        }
        let prompt = try #require(chat.lastPrompt)
        #expect(prompt.instructions == "Be brief.")
        #expect(
            prompt.history == [
                ChatTurn(role: .user, parts: [.text("Hi")]), ChatTurn(role: .assistant, parts: [.text("Hello.")]),
            ])
        #expect(prompt.prompt == [.text("How are you?")])
        #expect(prompt.options == ChatOptions(temperature: 0.5, maximumResponseTokens: 64))
    }

    @Test("Strict mode rejects an unknown model with model_not_found")
    func strictModels() async throws {
        let configuration = ServerConfiguration(strictModels: true)
        try await withServer(ServiceRegistry(chat: FakeChatService()), configuration: configuration) { client in
            try await client.post("/v1/chat/completions", json: chatBody(#""model": "gpt-4o""#)) { response in
                #expect(response.status == .notFound)
                #expect(response.error?.code == "model_not_found")
            }
            try await client.post(
                "/v1/chat/completions",
                json: chatBody(#""model": "apple-foundation-model""#)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test(
        "Unsupported or invalid requests return 400",
        arguments: [
            (chatBody(#""tools": [{"type": "function", "function": {"name": "f"}}]"#), "tools"),
            (chatBody(#""n": 2"#), "n"),
            (chatBody(#""temperature": 3"#), "temperature"),
            (chatBody(#""max_tokens": 0"#), "max_tokens"),
            (chatBody(#""response_format": {"type": "xml"}"#), "response_format.type"),
            (#"{"messages": [{"role": "tool", "content": "x", "tool_call_id": "1"}]}"#, "messages[0].role"),
            (#"{"messages": [{"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Yo"}]}"#, "messages"),
            (#"{"messages": []}"#, "messages"),
            (#"{"model": "gpt-4o"}"#, nil),
            (#"{"messages": "#, nil),
        ] as [(String, String?)]
    )
    func badRequests(body: String, param: String?) async throws {
        try await withServer(ServiceRegistry(chat: FakeChatService())) { client in
            try await client.post("/v1/chat/completions", json: body) { response in
                #expect(response.status == .badRequest)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                if let param {
                    #expect(error.param == param)
                }
            }
        }
    }

    @Test("A missing messages field names the parameter")
    func missingMessages() async throws {
        try await withServer(ServiceRegistry(chat: FakeChatService())) { client in
            try await client.post("/v1/chat/completions", json: #"{"model": "gpt-4o"}"#) { response in
                #expect(response.error?.message == "Missing required parameter: 'messages'.")
            }
        }
    }

    @Test("An unavailable model returns 503")
    func unavailable() async throws {
        let chat = FakeChatService(availability: .unavailable(reason: "Apple Intelligence is turned off."))
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: chatBody()) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.error?.message == "Apple Intelligence is turned off.")
            }
        }
        try await withServer(ServiceRegistry()) { client in
            try await client.post("/v1/chat/completions", json: chatBody()) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }

    @Test("Service errors keep their status and code")
    func serviceErrors() async throws {
        let chat = FakeChatService(result: .failure(.contextLengthExceeded("Too long.")))
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: chatBody()) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.code == "context_length_exceeded")
            }
        }
    }

    @Test("Images are rejected when the model doesn't accept them")
    func imagesRequireSupport() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let body = #"""
            {"messages": [{"role": "user", "content": [
              {"type": "text", "text": "What is this?"},
              {"type": "image_url", "image_url": {"url": "data:image/png;base64,\#(png)"}}
            ]}]}
            """#
        try await withServer(ServiceRegistry(chat: FakeChatService(supportsImageInput: false))) { client in
            try await client.post("/v1/chat/completions", json: body) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.message == "The model on this Mac does not accept images.")
            }
        }
        let chat = FakeChatService(supportsImageInput: true)
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: body) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(chat.lastPrompt?.prompt == [.text("What is this?"), .image(Data([0x89, 0x50, 0x4E, 0x47]))])
    }

    // MARK: - Streaming

    @Test("A stream sends a role chunk, deltas, a finish chunk, and [DONE]")
    func streaming() async throws {
        try await withServer(ServiceRegistry(chat: FakeChatService())) { client in
            try await client.post("/v1/chat/completions", json: chatBody(#""stream": true"#)) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/event-stream")
                let events = try ServerSentEventStream(response.text)
                #expect(events.isDone)
                let chunks = try events.chunks()
                #expect(
                    chunks.map(\.choices.first?.delta) == [
                        .init(role: "assistant", content: ""),
                        .init(content: "Hel"),
                        .init(content: "lo!"),
                        .init(),
                    ])
                #expect(chunks.map(\.choices.first?.finishReason) == [nil, nil, nil, "stop"])
                #expect(Set(chunks.map(\.id)).count == 1)
                #expect(chunks.allSatisfy { $0.object == "chat.completion.chunk" })
                #expect(chunks.allSatisfy { $0.model == "apple-foundation-model" })
                #expect(chunks.allSatisfy { $0.usage == nil })
            }
        }
    }

    @Test("A stream with include_usage ends with a usage chunk")
    func streamingUsage() async throws {
        let body = chatBody(#""stream": true, "stream_options": {"include_usage": true}"#)
        try await withServer(ServiceRegistry(chat: FakeChatService())) { client in
            try await client.post("/v1/chat/completions", json: body) { response in
                let chunks = try ServerSentEventStream(response.text).chunks()
                let last = try #require(chunks.last)
                #expect(last.choices.isEmpty)
                #expect(last.usage == ChatCompletionUsage(promptTokens: 5, completionTokens: 2))
            }
        }
    }

    @Test("An error before the first event returns an error status")
    func streamingEarlyError() async throws {
        let chat = FakeChatService(events: [], streamError: .contentPolicyViolation("Blocked."))
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: chatBody(#""stream": true"#)) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.code == "content_policy_violation")
            }
        }
    }

    @Test("An error during a stream sends an error event and no [DONE]")
    func streamingLateError() async throws {
        let chat = FakeChatService(events: [.delta("Hel")], streamError: .contentPolicyViolation("Blocked."))
        try await withServer(ServiceRegistry(chat: chat)) { client in
            try await client.post("/v1/chat/completions", json: chatBody(#""stream": true"#)) { response in
                #expect(response.status == .ok)
                let events = try ServerSentEventStream(response.text)
                #expect(!events.isDone)
                let last = try #require(events.payloads.last)
                let error = try JSONDecoder().decode(ErrorBody.self, from: Data(last.utf8))
                #expect(error.error.code == "content_policy_violation")
            }
        }
    }
}

/// Parses a server-sent event stream and checks its framing.
struct ServerSentEventStream {
    struct FramingError: Error, CustomStringConvertible {
        var description: String
    }

    /// The `data` value of each event, in order, without `[DONE]`.
    var payloads: [String] = []
    var isDone = false

    init(_ text: String) throws {
        guard text.hasSuffix("\n\n") else {
            throw FramingError(description: "The stream doesn't end with a blank line.")
        }
        for event in text.dropLast(2).components(separatedBy: "\n\n") {
            guard !isDone else {
                throw FramingError(description: "An event follows [DONE].")
            }
            guard event.hasPrefix("data: "), !event.contains("\n") else {
                throw FramingError(description: "The event \(event.debugDescription) isn't one data line.")
            }
            let data = String(event.dropFirst("data: ".count))
            if data == "[DONE]" {
                isDone = true
            } else {
                payloads.append(data)
            }
        }
    }

    func chunks() throws -> [ChatCompletionChunk] {
        try payloads.map { try JSONDecoder().decode(ChatCompletionChunk.self, from: Data($0.utf8)) }
    }
}
