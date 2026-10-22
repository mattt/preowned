import Foundation
import NaturalLanguage

/// An embedding service backed by NaturalLanguage's contextual embeddings.
///
/// NaturalLanguage offers two kinds of text embedding:
/// `NLEmbedding.sentenceEmbedding(for:)` and `NLContextualEmbedding`.
/// On macOS 27, the sentence embedding exists only for
/// English (512 dimensions), French, German, Italian, and Spanish (640 dimensions),
/// so one model ID would give vectors of different sizes,
/// and it reports no token counts.
/// The contextual embedding has one 512-dimension model for each script.
/// The Latin-script model covers 20 languages in one vector space,
/// and the model reports the tokens that it reads.
/// This service uses the contextual embedding
/// and mean-pools its token vectors into one vector for each input,
/// then scales the vector to unit length, as OpenAI's vectors are.
///
/// The model reads at most 256 tokens at a time,
/// so the service embeds a longer input in consecutive windows
/// and averages the token vectors of every window.
/// An input can have at most ``maximumTokensPerInput`` tokens, as with OpenAI.
///
/// The service picks a model by the input's dominant language.
/// Inputs in different scripts use different models,
/// so their vectors are not comparable.
public struct NaturalLanguageEmbeddingService: EmbeddingService, InventoryReporting {
    /// The most tokens in one input, as OpenAI allows.
    public static let maximumTokensPerInput = 8192

    private let models: ContextualEmbeddingModels
    private let allowAssetDownloads: Bool

    /// Creates the service.
    ///
    /// - Parameter allowAssetDownloads: Whether the service can download
    ///   a script's model when a request needs it.
    public init(allowAssetDownloads: Bool = false) {
        self.allowAssetDownloads = allowAssetDownloads
        self.models = ContextualEmbeddingModels(allowAssetDownloads: allowAssetDownloads)
    }

    public var availability: ServiceAvailability {
        guard let latin = NLContextualEmbedding(script: .latin) else {
            return .unavailable(reason: "NaturalLanguage has no contextual embedding model on this Mac.")
        }
        if latin.hasAvailableAssets || allowAssetDownloads {
            return .available
        }
        return .unavailable(reason: ContextualEmbeddingModels.notDownloadedMessage(for: latin))
    }

    public var dimensions: Int {
        NLContextualEmbedding(script: .latin)?.dimension ?? 512
    }

    public func embed(_ inputs: [String]) async throws -> Embeddings {
        try await models.embed(inputs, dimensions: dimensions)
    }

    public func inventoryDetails() async -> [String] {
        ContextualEmbeddingModels.allModels().map { model in
            let state = model.hasAvailableAssets ? "installed" : "not downloaded"
            let scripts = model.scripts.map(\.rawValue).sorted().joined(separator: ", ")
            let languages = model.languages.map(\.rawValue).sorted().joined(separator: ", ")
            return "\(scripts) model (\(model.dimension) dimensions), \(state): \(languages)"
        }
    }
}

/// The loaded contextual embedding models, one for each script.
///
/// The actor serializes access,
/// because NaturalLanguage doesn't document `NLContextualEmbedding` as thread-safe.
private actor ContextualEmbeddingModels {
    let allowAssetDownloads: Bool
    private var loaded: [String: NLContextualEmbedding] = [:]

    init(allowAssetDownloads: Bool) {
        self.allowAssetDownloads = allowAssetDownloads
    }

    func embed(_ inputs: [String], dimensions: Int) async throws -> Embeddings {
        var vectors: [[Float]] = []
        var tokenCount = 0
        for input in inputs {
            let model = try await model(for: input)
            guard model.dimension == dimensions else {
                throw OpenAIError.server(
                    "The NaturalLanguage model for this text has \(model.dimension) dimensions, "
                        + "not \(dimensions)."
                )
            }
            let (vector, tokens) = try Self.meanPooledVector(of: input, model: model)
            vectors.append(vector)
            tokenCount += tokens
        }
        return Embeddings(vectors: vectors, tokenCount: tokenCount)
    }

    /// The loaded model for the script of a text's dominant language.
    private func model(for text: String) async throws -> NLContextualEmbedding {
        let language = NLLanguageRecognizer.dominantLanguage(for: text)
        let candidate =
            language.flatMap { NLContextualEmbedding(language: $0) }
            ?? NLContextualEmbedding(script: .latin)
        guard let candidate else {
            throw OpenAIError.serviceUnavailable("NaturalLanguage has no contextual embedding model on this Mac.")
        }
        if let model = loaded[candidate.modelIdentifier] {
            return model
        }

        if !candidate.hasAvailableAssets {
            guard allowAssetDownloads else {
                throw OpenAIError.serviceUnavailable(Self.notDownloadedMessage(for: candidate))
            }
            let result: NLContextualEmbedding.AssetsResult
            do {
                result = try await candidate.requestAssets()
            } catch {
                throw OpenAIError.serviceUnavailable(
                    "NaturalLanguage could not download the embedding model: \(error.localizedDescription)"
                )
            }
            guard result == .available else {
                throw OpenAIError.serviceUnavailable(
                    "NaturalLanguage could not download the embedding model for \(Self.scripts(of: candidate))."
                )
            }
        }

        do {
            try candidate.load()
        } catch {
            throw OpenAIError.serviceUnavailable(
                "NaturalLanguage could not load the embedding model: \(error.localizedDescription)"
            )
        }
        loaded[candidate.modelIdentifier] = candidate
        return candidate
    }

    /// The mean of a text's token vectors, scaled to unit length,
    /// and the number of tokens that the model read.
    private static func meanPooledVector(
        of text: String,
        model: NLContextualEmbedding
    ) throws -> ([Float], Int) {
        var sum = [Double](repeating: 0, count: model.dimension)
        var vectorCount = 0
        var tokenCount = 0
        var remainder = text

        while !remainder.allSatisfy(\.isWhitespace) {
            let result: NLContextualEmbeddingResult
            do {
                result = try model.embeddingResult(for: remainder, language: nil)
            } catch {
                throw OpenAIError.server("NaturalLanguage could not embed the input: \(error.localizedDescription)")
            }
            tokenCount += result.sequenceLength
            guard tokenCount <= NaturalLanguageEmbeddingService.maximumTokensPerInput else {
                throw OpenAIError.invalidRequest(
                    "This model's maximum context length is "
                        + "\(NaturalLanguageEmbeddingService.maximumTokensPerInput) tokens for each input, "
                        + "and an input is longer. Shorten or split the input.",
                    param: "input",
                    code: "context_length_exceeded"
                )
            }

            // The model reads only the start of a long window,
            // so the next window starts after the last token that it read.
            var end = remainder.startIndex
            result.enumerateTokenVectors(in: remainder.startIndex..<remainder.endIndex) { vector, range in
                for index in vector.indices where index < sum.count {
                    sum[index] += vector[index]
                }
                vectorCount += 1
                end = max(end, range.upperBound)
                return true
            }
            guard end > remainder.startIndex else { break }
            remainder = String(remainder[end...])
        }

        guard vectorCount > 0 else {
            return ([Float](repeating: 0, count: model.dimension), tokenCount)
        }
        let mean = sum.map { $0 / Double(vectorCount) }
        let length = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let normalized = length > 0 ? mean.map { $0 / length } : mean
        return (normalized.map(Float.init), tokenCount)
    }

    /// Every contextual embedding model, once each.
    static func allModels() -> [NLContextualEmbedding] {
        let scripts: [NLScript] = [
            .latin, .cyrillic, .simplifiedChinese, .traditionalChinese, .japanese, .korean,
            .arabic, .hebrew, .greek, .devanagari, .bengali, .gujarati, .gurmukhi, .kannada,
            .malayalam, .tamil, .telugu, .oriya, .sinhala, .thai, .khmer, .lao, .myanmar,
            .tibetan, .armenian, .georgian, .ethiopic, .mongolian, .cherokee,
            .canadianAboriginalSyllabics,
        ]
        var seen: Set<String> = []
        return scripts.compactMap { NLContextualEmbedding(script: $0) }.filter {
            seen.insert($0.modelIdentifier).inserted
        }
    }

    static func scripts(of model: NLContextualEmbedding) -> String {
        model.scripts.map(\.rawValue).sorted().joined(separator: ", ") + " script"
    }

    static func notDownloadedMessage(for model: NLContextualEmbedding) -> String {
        "The NaturalLanguage embedding model for \(scripts(of: model)) is not downloaded on this Mac. "
            + "Restart the server with `preowned serve --allow-asset-downloads` to let it download the model."
    }
}
