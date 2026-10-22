/// The services that the server can use, one for each capability.
///
/// A capability without a service is unavailable,
/// with the reason ``ServiceRegistry/notImplementedReason``.
public struct ServiceRegistry: Sendable {
    public var chat: (any ChatService)?
    public var images: (any ImageService)?
    public var embeddings: (any EmbeddingService)?
    public var transcription: (any TranscriptionService)?
    public var speech: (any SpeechService)?

    /// The reason for a capability that has no implementation yet.
    public static let notImplementedReason = "Not on the lot yet."

    public init(
        chat: (any ChatService)? = nil,
        images: (any ImageService)? = nil,
        embeddings: (any EmbeddingService)? = nil,
        transcription: (any TranscriptionService)? = nil,
        speech: (any SpeechService)? = nil
    ) {
        self.chat = chat
        self.images = images
        self.embeddings = embeddings
        self.transcription = transcription
        self.speech = speech
    }

    /// The services backed by the Apple frameworks on this Mac.
    ///
    /// - Parameter allowAssetDownloads: Whether services can download
    ///   the language assets that a request needs.
    public static func system(allowAssetDownloads: Bool = false) -> ServiceRegistry {
        ServiceRegistry(
            chat: FoundationModelsChatService(),
            embeddings: NaturalLanguageEmbeddingService(allowAssetDownloads: allowAssetDownloads),
            transcription: SpeechTranscriptionService(allowAssetDownloads: allowAssetDownloads),
            speech: SystemSpeechService()
        )
    }

    /// Whether the service for a capability can handle requests,
    /// and why not if it can't.
    public func availability(of capability: Capability) -> ServiceAvailability {
        let availability: ServiceAvailability? =
            switch capability {
            case .chat: chat?.availability
            case .images: images?.availability
            case .embeddings: embeddings?.availability
            case .transcription: transcription?.availability
            case .speech: speech?.availability
            }
        return availability ?? .unavailable(reason: Self.notImplementedReason)
    }

    /// The capabilities that can handle requests now.
    public var availableCapabilities: [Capability] {
        Capability.allCases.filter { availability(of: $0).isAvailable }
    }
}
