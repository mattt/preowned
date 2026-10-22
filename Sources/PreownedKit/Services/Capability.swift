/// A capability that preowned serves through the OpenAI API.
///
/// Each capability has one backing model.
/// Its canonical model ID is the only place where that ID is spelled,
/// so a later rename changes one line.
public enum Capability: String, CaseIterable, Sendable {
    case chat
    case images
    case embeddings
    case transcription
    case speech

    /// The canonical model ID that responses and `GET /v1/models` report.
    public var modelID: String {
        switch self {
        case .chat: "apple-foundation-model"
        case .images: "apple-image-playground"
        case .embeddings: "apple-nl-embedding"
        case .transcription: "apple-speech-transcriber"
        case .speech: "apple-speech-synthesizer"
        }
    }

    /// A short name for the capability.
    public var displayName: String {
        switch self {
        case .chat: "Chat completions"
        case .images: "Images"
        case .embeddings: "Embeddings"
        case .transcription: "Transcriptions"
        case .speech: "Speech"
        }
    }

    /// The Apple framework that backs the capability.
    public var framework: String {
        switch self {
        case .chat: "Foundation Models"
        case .images: "Image Playground"
        case .embeddings: "NaturalLanguage"
        case .transcription: "Speech"
        case .speech: "AVFoundation"
        }
    }

    /// The capability whose canonical model ID is `modelID`, if any.
    public init?(modelID: String) {
        guard let capability = Self.allCases.first(where: { $0.modelID == modelID }) else {
            return nil
        }
        self = capability
    }
}

/// Whether a service can handle requests on this Mac.
public enum ServiceAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        self == .available
    }

    /// The reason that the service is unavailable, if it is.
    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}
