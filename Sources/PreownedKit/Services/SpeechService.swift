import Foundation

/// A service that synthesizes speech, as AVSpeechSynthesizer does.
public protocol SpeechService: Sendable {
    var availability: ServiceAvailability { get }

    /// The audio formats that the service can produce.
    var supportedFormats: [SpeechAudioFormat] { get }

    /// Synthesizes speech for a text.
    func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech
}

/// An audio format for synthesized speech.
///
/// Every format has 24 kHz mono samples, as OpenAI's do,
/// except Opus, which always codes at 48 kHz.
public enum SpeechAudioFormat: String, Sendable, CaseIterable {
    /// 16-bit WAV.
    case wav
    /// Raw 16-bit signed little-endian samples, without a header.
    case pcm
    /// AAC in an ADTS stream.
    case aac
    /// FLAC.
    case flac
    /// Opus in an Ogg container.
    case opus

    /// The `Content-Type` of the format.
    public var contentType: String {
        switch self {
        case .wav: "audio/wav"
        case .pcm: "audio/pcm"
        case .aac: "audio/aac"
        case .flac: "audio/flac"
        case .opus: "audio/ogg"
        }
    }
}

/// A request to synthesize speech.
public struct SpeechRequest: Sendable, Equatable {
    public var input: String
    /// An OpenAI voice name, such as `alloy`,
    /// or the name or identifier of a system voice.
    public var voice: String
    /// A rate multiplier from 0.25 to 4.0.
    public var speed: Double
    public var format: SpeechAudioFormat

    public init(input: String, voice: String, speed: Double = 1, format: SpeechAudioFormat = .wav) {
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
