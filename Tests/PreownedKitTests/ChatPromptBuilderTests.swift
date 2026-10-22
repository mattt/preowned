import Foundation
import Testing

@testable import PreownedKit

@Suite("Chat prompt conversion")
struct ChatPromptBuilderTests {
    private func request(_ json: String) throws -> ChatCompletionRequest {
        try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
    }

    @Test("System and developer messages join into instructions")
    func instructions() throws {
        let prompt = try ChatPromptBuilder.prompt(
            for: request(
                #"""
                {"messages": [
                  {"role": "system", "content": "One."},
                  {"role": "developer", "content": [{"type": "text", "text": "Two."}]},
                  {"role": "user", "content": "Hi"}
                ]}
                """#
            )
        )
        #expect(prompt.instructions == "One.\n\nTwo.")
        #expect(prompt.history.isEmpty)
        #expect(prompt.prompt == [.text("Hi")])
        #expect(prompt.format == .text)
    }

    @Test("max_completion_tokens takes precedence over max_tokens")
    func maximumTokens() throws {
        let prompt = try ChatPromptBuilder.prompt(
            for: request(chatBody(#""max_tokens": 10, "max_completion_tokens": 20"#))
        )
        #expect(prompt.options.maximumResponseTokens == 20)
    }

    @Test("json_object adds an instruction")
    func jsonObject() throws {
        let prompt = try ChatPromptBuilder.prompt(
            for: request(chatBody(#""response_format": {"type": "json_object"}"#))
        )
        #expect(prompt.format == .jsonObject)
        #expect(prompt.instructions == ChatPromptBuilder.jsonObjectInstruction)
    }

    @Test("json_schema converts the schema")
    func jsonSchema() throws {
        let prompt = try ChatPromptBuilder.prompt(
            for: request(
                chatBody(
                    #"""
                    "response_format": {"type": "json_schema", "json_schema": {
                      "name": "Answer",
                      "schema": {"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"]}
                    }}
                    """#
                )
            )
        )
        let expected = SchemaNode.object(SchemaObject(properties: [SchemaProperty(name: "ok", schema: .boolean)]))
        #expect(prompt.format == .jsonSchema(name: "Answer", schema: expected, definitions: [:]))
    }

    @Test("json_schema rejects unsupported keywords")
    func jsonSchemaRejects() throws {
        let error = #expect(throws: OpenAIError.self) {
            try ChatPromptBuilder.prompt(
                for: request(
                    chatBody(
                        #"""
                        "response_format": {"type": "json_schema", "json_schema": {
                          "name": "Answer", "schema": {"type": "string", "minLength": 3}
                        }}
                        """#
                    )
                )
            )
        }
        #expect(error?.param == "response_format")
        #expect(error?.message.contains("minLength") == true)
    }

    @Test("Image data URLs decode, and other URLs are rejected")
    func imageURLs() throws {
        let data = try ChatPromptBuilder.imageData(from: "data:image/png;base64,AAEC", param: "p")
        #expect(data == Data([0, 1, 2]))

        for url in ["https://example.com/cat.png", "data:text/plain;base64,AAEC", "data:image/png,AAEC"] {
            #expect(throws: OpenAIError.self) {
                try ChatPromptBuilder.imageData(from: url, param: "p")
            }
        }
    }

    @Test("Images in assistant or system messages are rejected")
    func imagesOnlyFromUser() throws {
        let error = #expect(throws: OpenAIError.self) {
            try ChatPromptBuilder.prompt(
                for: request(
                    #"""
                    {"messages": [
                      {"role": "system", "content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,AAEC"}}]},
                      {"role": "user", "content": "Hi"}
                    ]}
                    """#
                )
            )
        }
        #expect(error?.param == "messages[0].content")
    }

    @Test("Unsupported content parts are rejected")
    func unsupportedParts() throws {
        let error = #expect(throws: OpenAIError.self) {
            try ChatPromptBuilder.prompt(
                for: request(#"{"messages": [{"role": "user", "content": [{"type": "input_audio"}]}]}"#)
            )
        }
        #expect(error?.param == "messages[0].content[0].type")
    }

    @Test("Assistant tool calls are rejected")
    func toolCalls() throws {
        let error = #expect(throws: OpenAIError.self) {
            try ChatPromptBuilder.prompt(
                for: request(
                    #"""
                    {"messages": [
                      {"role": "user", "content": "Hi"},
                      {"role": "assistant", "content": null, "tool_calls": [{"id": "1"}]},
                      {"role": "user", "content": "Hi"}
                    ]}
                    """#
                )
            )
        }
        #expect(error?.param == "messages[1].tool_calls")
    }
}

@Suite("Streaming and response helpers")
struct HelperTests {
    @Test("Deltas extend the emitted text")
    func snapshotDeltas() {
        var differ = SnapshotDiffer()
        #expect(differ.delta(for: "") == nil)
        #expect(differ.delta(for: "Hel") == "Hel")
        #expect(differ.delta(for: "Hel") == nil)
        #expect(differ.delta(for: "Hello") == "lo")
        // A snapshot that rewrites earlier text produces no delta.
        #expect(differ.delta(for: "Help") == nil)
        #expect(differ.emitted == "Hello")
        #expect(differ.delta(for: "Hello, world") == ", world")
    }

    @Test("A combining mark produces a delta")
    func combiningMark() {
        var differ = SnapshotDiffer()
        #expect(differ.delta(for: "cafe") == "cafe")
        #expect(differ.delta(for: "cafe\u{301}") == "\u{301}")
        #expect(differ.emitted == "café")
    }

    @Test(
        "Code fences are removed from JSON responses",
        arguments: [
            (#"{"a": 1}"#, #"{"a": 1}"#),
            ("```json\n{\"a\": 1}\n```", #"{"a": 1}"#),
            ("```\n{\"a\": 1}\n```", #"{"a": 1}"#),
            ("  {\"a\": 1}\n", #"{"a": 1}"#),
        ]
    )
    func codeFences(input: String, expected: String) {
        #expect(FoundationModelsChatService.removingCodeFence(from: input) == expected)
    }

    @Test("Estimated usage counts four characters for each token")
    func estimatedUsage() {
        let prompt = ChatPrompt(instructions: "abcd", prompt: [.text("efgh")])
        let usage = FoundationModelsChatService.estimatedUsage(prompt: prompt, content: "abcdefgh")
        #expect(usage == ChatUsage(promptTokens: 3, completionTokens: 2, isEstimated: true))
    }
}
