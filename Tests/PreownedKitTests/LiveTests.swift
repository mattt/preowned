import Foundation
import Testing

@testable import PreownedKit

/// Tests that call the on-device model.
///
/// They run only when `PREOWNED_LIVE_TESTS=1`,
/// because they need Apple Intelligence and take seconds each.
@Suite(
    "Live Foundation Models",
    .enabled(if: ProcessInfo.processInfo.environment["PREOWNED_LIVE_TESTS"] == "1"),
    .serialized
)
struct LiveTests {
    let service = FoundationModelsChatService()

    @Test("The model responds")
    func respond() async throws {
        try #require(service.availability == .available)
        let result = try await service.respond(
            to: ChatPrompt(
                instructions: "Answer in one word.",
                prompt: [.text("What color is the sky on a clear day?")]
            )
        )
        #expect(!result.content.isEmpty)
        #expect(result.usage.completionTokens > 0)
    }

    @Test("The model streams deltas and a summary")
    func stream() async throws {
        try #require(service.availability == .available)
        var text = ""
        var summary: ChatStreamSummary?
        for try await event in service.streamResponse(to: ChatPrompt(prompt: [.text("Count from 1 to 5.")])) {
            switch event {
            case .delta(let delta): text += delta
            case .finished(let final): summary = final
            }
        }
        #expect(text.contains("3"))
        #expect(summary != nil)
    }

    @Test("The model follows a JSON Schema")
    func structured() async throws {
        try #require(service.availability == .available)
        let schema = try JSONSchemaParser().parse(
            .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")]),
                    "population": .object(["type": .string("integer"), "minimum": .number(0)]),
                ]),
                "required": .array([.string("city"), .string("population")]),
            ])
        )
        let result = try await service.respond(
            to: ChatPrompt(
                prompt: [.text("Describe Paris.")],
                format: .jsonSchema(name: "City", schema: schema.root, definitions: schema.definitions)
            )
        )
        let object = try JSONDecoder().decode([String: JSONValue].self, from: Data(result.content.utf8))
        #expect(object["city"]?.stringValue != nil)
        #expect(object["population"]?.integerValue != nil)
    }
}
