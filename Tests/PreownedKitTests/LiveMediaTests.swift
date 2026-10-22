import Foundation
import Testing

@testable import PreownedKit

/// Tests that call the NaturalLanguage, Speech, Translation, and AVFoundation services.
///
/// They run only when `PREOWNED_LIVE_TESTS=1`,
/// because they depend on the assets installed on this Mac.
@Suite(
    "Live embeddings and audio",
    .enabled(if: ProcessInfo.processInfo.environment["PREOWNED_LIVE_TESTS"] == "1"),
    .serialized
)
struct LiveMediaTests {
    @Test("Similar sentences have closer vectors than unrelated ones")
    func embeddings() async throws {
        let service = NaturalLanguageEmbeddingService()
        try #require(service.availability == .available)
        let result = try await service.embed([
            "How do I reset my password?",
            "I forgot my login and need to change it.",
            "The weather will be sunny tomorrow.",
        ])
        #expect(result.vectors.count == 3)
        #expect(result.vectors.allSatisfy { $0.count == service.dimensions })
        #expect(result.tokenCount > 0)
        func dot(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        #expect(abs(dot(result.vectors[0], result.vectors[0]) - 1) < 0.001)
        #expect(dot(result.vectors[0], result.vectors[1]) > dot(result.vectors[0], result.vectors[2]))
    }

    @Test("A long input embeds in windows and counts every token")
    func longEmbedding() async throws {
        let service = NaturalLanguageEmbeddingService()
        try #require(service.availability == .available)
        let sentence = "The quick brown fox jumps over the lazy dog. "
        let short = try await service.embed([sentence])
        let long = try await service.embed([String(repeating: sentence, count: 40)])
        #expect(long.tokenCount > 256)
        #expect(long.tokenCount > short.tokenCount * 30)
    }
}
