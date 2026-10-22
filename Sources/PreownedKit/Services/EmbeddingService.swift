/// A service that computes text embeddings, as NaturalLanguage does.
public protocol EmbeddingService: Sendable {
    var availability: ServiceAvailability { get }

    /// The number of dimensions in each vector.
    var dimensions: Int { get }

    /// Computes one vector for each input string, in order.
    func embed(_ inputs: [String]) async throws -> Embeddings
}

/// The vectors for a list of inputs, with the tokens that the model read.
public struct Embeddings: Sendable, Equatable {
    /// One vector for each input, in order.
    public var vectors: [[Float]]
    /// The number of tokens in all inputs, as the model counts them.
    public var tokenCount: Int

    public init(vectors: [[Float]], tokenCount: Int) {
        self.vectors = vectors
        self.tokenCount = tokenCount
    }
}
