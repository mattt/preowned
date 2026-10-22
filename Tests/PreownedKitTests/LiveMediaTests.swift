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

    /// Records a sentence with `say`, then converts it with `afconvert`.
    func recording(_ text: String, voice: String? = nil, format: (file: String, data: String)) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preowned-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appendingPathComponent("speech.aiff")
        let output = directory.appendingPathComponent("speech.out")
        try run("/usr/bin/say", ["-o", aiff.path] + (voice.map { ["-v", $0] } ?? []) + [text])
        try run("/usr/bin/afconvert", ["-f", format.file, "-d", format.data, aiff.path, output.path])
        return try Data(contentsOf: output)
    }

    func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test(
        "Speech transcribes a recording in each container",
        arguments: [
            ("speech.wav", "WAVE", "LEI16@16000"),
            ("speech.m4a", "m4af", "aac"),
            ("speech.flac", "flac", "flac"),
            ("speech.caf", "caff", "LEI16"),
            ("speech.aac", "adts", "aac"),
        ]
    )
    func transcription(filename: String, fileFormat: String, dataFormat: String) async throws {
        let service = SpeechTranscriptionService()
        try #require(service.availability == .available)
        let audio = try recording(
            "The used car lot opens at nine tomorrow morning.",
            format: (fileFormat, dataFormat)
        )
        let transcription = try await service.transcribe(
            TranscriptionRequest(audio: audio, filename: filename, language: "en", includeWords: true)
        )
        #expect(transcription.text.lowercased().contains("car lot"))
        #expect(transcription.language?.hasPrefix("en") == true)
        #expect((transcription.duration ?? 0) > 1)
        #expect(!transcription.segments.isEmpty)
        #expect(transcription.words.contains { $0.word.lowercased().hasPrefix("tomorrow") })
    }

    @Test("Audio that Core Audio can't read is a 400")
    func unreadableAudio() async throws {
        let service = SpeechTranscriptionService()
        try #require(service.availability == .available)
        let error = await #expect(throws: OpenAIError.self) {
            try await service.transcribe(
                TranscriptionRequest(audio: Data("not audio at all".utf8), filename: "speech.webm", language: "en")
            )
        }
        #expect(error?.status == .badRequest)
        #expect(error?.code == "invalid_file_format")
    }

    @Test("French audio translates into English, or reports what to install")
    func translation() async throws {
        let service = SpeechTranscriptionService()
        try #require(service.availability == .available)
        let audio = try recording(
            "Je voudrais acheter une voiture d'occasion.",
            voice: "Thomas",
            format: ("WAVE", "LEI16@16000")
        )
        do {
            let translation = try await service.translate(
                TranscriptionRequest(audio: audio, filename: "speech.wav", language: "fr")
            )
            #expect(translation.language == "en")
            #expect(translation.text.lowercased().contains("car"))
        } catch let error as OpenAIError {
            // The French speech model or translation may not be installed on this Mac.
            #expect(error.status == .serviceUnavailable)
            #expect(error.code == "service_unavailable")
        }
    }
}
