import Foundation

/// A service that synthesizes speech, as AVSpeechSynthesizer does.
public protocol SpeechService: Sendable {
    var availability: ServiceAvailability { get }

    /// The audio formats that the service can produce,
    /// as OpenAI `response_format` values.
    var supportedFormats: [String] { get }

    /// Synthesizes speech for a text.
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech
}

/// A request to synthesize speech.
public struct SpeechRequest: Sendable, Equatable {
    public var input: String
    /// An OpenAI voice name, such as `alloy`.
    public var voice: String
    /// A rate multiplier from 0.25 to 4.0.
    public var speed: Double
    /// An OpenAI `response_format` value, such as `wav`.
    public var format: String

    public init(input: String, voice: String, speed: Double = 1, format: String = "wav") {
        self.input = input
        self.voice = voice
        self.speed = speed
        self.format = format
    }
}

/// Synthesized audio.
public struct SynthesizedSpeech: Sendable, Equatable {
    public var data: Data
    public var contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}
