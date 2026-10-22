import Testing

@testable import PreownedKit

@Suite("Model resolution")
struct ModelResolverTests {
    @Test("By default, any model name resolves to the canonical ID")
    func lenient() throws {
        let resolver = ModelResolver()
        #expect(try resolver.resolve("gpt-4o", for: .chat) == "apple-foundation-model")
        #expect(try resolver.resolve(nil, for: .chat) == "apple-foundation-model")
        #expect(try resolver.resolve("", for: .chat) == "apple-foundation-model")
        #expect(try resolver.resolve("apple-foundation-model", for: .chat) == "apple-foundation-model")
    }

    @Test("Strict mode rejects names other than the canonical ID")
    func strict() throws {
        let resolver = ModelResolver(isStrict: true)
        #expect(try resolver.resolve("apple-foundation-model", for: .chat) == "apple-foundation-model")
        #expect(throws: OpenAIError.modelNotFound("gpt-4o")) {
            try resolver.resolve("gpt-4o", for: .chat)
        }
        let error = #expect(throws: OpenAIError.self) {
            try resolver.resolve(nil, for: .chat)
        }
        #expect(error?.param == "model")
        #expect(error?.status == .badRequest)
    }

    @Test("A canonical ID for another capability is a mistake in either mode", arguments: [false, true])
    func canonicalMismatch(isStrict: Bool) {
        let error = #expect(throws: OpenAIError.self) {
            try ModelResolver(isStrict: isStrict).resolve("apple-nl-embedding", for: .chat)
        }
        #expect(error?.status == .badRequest)
        #expect(error?.code == "model_not_supported")
    }

    @Test("Each capability has a distinct canonical ID")
    func canonicalIDs() {
        let ids = Capability.allCases.map(\.modelID)
        #expect(Set(ids).count == ids.count)
        for capability in Capability.allCases {
            #expect(Capability(modelID: capability.modelID) == capability)
        }
    }
}
