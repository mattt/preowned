/// The body of `POST /v1/audio/speech`.
///
/// The decoder ignores `instructions`,
/// because AVSpeechSynthesizer has no way to steer delivery with a prompt.
public struct SpeechCreateRequest: Decodable, Sendable, Equatable {
    public var model: String?
    public var input: String
    public var voice: String
    public var responseFormat: String?
    public var speed: Double?
    public var streamFormat: String?

    public init(
        model: String? = nil,
        input: String,
        voice: String,
        responseFormat: String? = nil,
        speed: Double? = nil,
        streamFormat: String? = nil
    ) {
        self.model = model
        self.input = input
        self.voice = voice
        self.responseFormat = responseFormat
        self.speed = speed
        self.streamFormat = streamFormat
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case responseFormat = "response_format"
        case speed
        case streamFormat = "stream_format"
    }
}
