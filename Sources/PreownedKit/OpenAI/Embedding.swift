import Foundation

// MARK: - Request

/// The body of `POST /v1/embeddings`.
///
/// The decoder ignores `user` and other unknown fields.
public struct EmbeddingRequest: Decodable, Sendable, Equatable {
    public var model: String?
    public var input: EmbeddingInput
    public var encodingFormat: String?
    public var dimensions: Int?

    public init(
        model: String? = nil,
        input: EmbeddingInput,
        encodingFormat: String? = nil,
        dimensions: Int? = nil
    ) {
        self.model = model
        self.input = input
        self.encodingFormat = encodingFormat
        self.dimensions = dimensions
    }

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case encodingFormat = "encoding_format"
        case dimensions
    }
}

/// The `input` of an embedding request:
/// a string, an array of strings, or token arrays.
public enum EmbeddingInput: Decodable, Sendable, Equatable {
    case strings([String])
    /// One or more arrays of token IDs, which preowned rejects,
    /// because its models don't share OpenAI's tokenizer.
    case tokens([[Int]])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .strings([string])
        } else if let strings = try? container.decode([String].self) {
            self = .strings(strings)
        } else if let tokens = try? container.decode([Int].self) {
            self = .tokens([tokens])
        } else if let tokens = try? container.decode([[Int]].self) {
            self = .tokens(tokens)
        } else {
            throw DecodingError.typeMismatch(
                EmbeddingInput.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or an array.")
            )
        }
    }
}

// MARK: - Response

/// The response of `POST /v1/embeddings`.
public struct EmbeddingResponse: Codable, Sendable, Equatable {
    public var object: String
    public var data: [EmbeddingObject]
    public var model: String
    public var usage: EmbeddingUsage

    public init(data: [EmbeddingObject], model: String, usage: EmbeddingUsage) {
        self.object = "list"
        self.data = data
        self.model = model
        self.usage = usage
    }
}

/// One vector in an embedding response.
public struct EmbeddingObject: Codable, Sendable, Equatable {
    public var object: String
    public var index: Int
    public var embedding: EmbeddingVector

    public init(index: Int, embedding: EmbeddingVector) {
        self.object = "embedding"
        self.index = index
        self.embedding = embedding
    }
}

/// A vector as an array of numbers or as base64.
public enum EmbeddingVector: Codable, Sendable, Equatable {
    case float([Float])
    /// The vector's little-endian 32-bit floats, encoded as base64.
    case base64(String)

    /// Encodes a vector in the format that a request names.
    public init(_ vector: [Float], base64: Bool) {
        if base64 {
            var data = Data(capacity: vector.count * 4)
            for value in vector {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            self = .base64(data.base64EncodedString())
        } else {
            self = .float(vector)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .base64(string)
        } else {
            self = .float(try container.decode([Float].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .float(let vector): try container.encode(vector)
        case .base64(let string): try container.encode(string)
        }
    }

    /// The vector's values, decoding base64 if needed.
    public var values: [Float]? {
        switch self {
        case .float(let vector):
            return vector
        case .base64(let string):
            guard let data = Data(base64Encoded: string), data.count % 4 == 0 else { return nil }
            return stride(from: 0, to: data.count, by: 4).map { offset in
                let bits = data[data.startIndex + offset..<data.startIndex + offset + 4]
                    .reversed()
                    .reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                return Float(bitPattern: bits)
            }
        }
    }
}

/// Token usage for an embedding request.
public struct EmbeddingUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int) {
        self.promptTokens = promptTokens
        self.totalTokens = promptTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}
