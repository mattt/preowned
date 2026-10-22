import Foundation

// These protocols define the capabilities that later phases implement.
// The server registers no routes for them yet,
// so `GET /v1/models` leaves their models out
// and their endpoints return OpenAI's 404 for an unknown URL.
// A phase that adds an implementation also adds its routes.

// MARK: - Images

/// A service that creates images, as Image Playground does.
public protocol ImageService: Sendable {
    var availability: ServiceAvailability { get }

    /// The style names that the service accepts.
    var availableStyles: [String] { get }

    /// Creates images from a text prompt and an optional source image.
    func generateImages(_ request: ImageGenerationRequest) async throws -> [GeneratedImage]
}

/// A request to create images.
public struct ImageGenerationRequest: Sendable, Equatable {
    public var prompt: String
    /// Encoded source image data for edits and variations.
    public var sourceImage: Data?
    public var count: Int
    public var style: String?

    public init(prompt: String, sourceImage: Data? = nil, count: Int = 1, style: String? = nil) {
        self.prompt = prompt
        self.sourceImage = sourceImage
        self.count = count
        self.style = style
    }
}

/// An image that a service created.
public struct GeneratedImage: Sendable, Equatable {
    /// PNG data.
    public var pngData: Data

    public init(pngData: Data) {
        self.pngData = pngData
    }
}

// MARK: - Embeddings

/// A service that computes text embeddings, as NaturalLanguage does.
public protocol EmbeddingService: Sendable {
    var availability: ServiceAvailability { get }

    /// The number of dimensions in each vector.
    var dimensions: Int { get }

    /// Computes one vector for each input string, in order.
    func embed(_ inputs: [String]) async throws -> [[Float]]
}

// MARK: - Transcription

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

// MARK: - Speech

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
