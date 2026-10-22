import Foundation

/// A service that transcribes and translates speech, as Speech does.
public protocol TranscriptionService: Sendable {
    var availability: ServiceAvailability { get }

    /// Transcribes audio in its spoken language.
    func transcribe(_ request: TranscriptionRequest) async throws -> Transcription

    /// Transcribes audio, then translates the text into English.
    func translate(_ request: TranscriptionRequest) async throws -> Transcription
}

/// A request to transcribe audio.
public struct TranscriptionRequest: Sendable, Equatable {
    /// Encoded audio data.
    public var audio: Data
    /// The file name from the upload, which hints at the audio format.
    public var filename: String?
    /// The spoken language as an ISO 639-1 code, if the client knows it.
    public var language: String?
    /// Text that guides the transcription.
    public var prompt: String?

    public init(audio: Data, filename: String? = nil, language: String? = nil, prompt: String? = nil) {
        self.audio = audio
        self.filename = filename
        self.language = language
        self.prompt = prompt
    }
}

/// The text of a transcription, with timed segments.
public struct Transcription: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var text: String
    public var language: String?
    public var duration: TimeInterval?
    public var segments: [Segment]

    public init(
        text: String,
        language: String? = nil,
        duration: TimeInterval? = nil,
        segments: [Segment] = []
    ) {
        self.text = text
        self.language = language
        self.duration = duration
        self.segments = segments
    }
}
