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
    /// The spoken language as an ISO 639-1 code or a BCP 47 identifier,
    /// if the client knows it.
    public var language: String?
    /// Text that guides the transcription.
    public var prompt: String?
    /// Whether the result needs the time of each word.
    public var includeWords: Bool

    public init(
        audio: Data,
        filename: String? = nil,
        language: String? = nil,
        prompt: String? = nil,
        includeWords: Bool = false
    ) {
        self.audio = audio
        self.filename = filename
        self.language = language
        self.prompt = prompt
        self.includeWords = includeWords
    }
}

/// The text of a transcription, with timed segments.
public struct Transcription: Sendable, Equatable {
    /// A phrase with its time in the audio.
    public struct Segment: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        /// The model's mean confidence in the segment's words, from 0 to 1, if it reports one.
        public var confidence: Double?

        public init(start: TimeInterval, end: TimeInterval, text: String, confidence: Double? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.confidence = confidence
        }
    }

    /// A word with its time in the audio.
    public struct Word: Sendable, Equatable {
        public var word: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(word: String, start: TimeInterval, end: TimeInterval) {
            self.word = word
            self.start = start
            self.end = end
        }
    }

    public var text: String
    /// The language of `text` as a BCP 47 identifier, such as `en-US`.
    public var language: String?
    /// The length of the audio in seconds.
    public var duration: TimeInterval?
    public var segments: [Segment]
    public var words: [Word]

    public init(
        text: String,
        language: String? = nil,
        duration: TimeInterval? = nil,
        segments: [Segment] = [],
        words: [Word] = []
    ) {
        self.text = text
        self.language = language
        self.duration = duration
        self.segments = segments
        self.words = words
    }
}
