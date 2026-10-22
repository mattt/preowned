import Foundation

// MARK: - Request

/// The JSON body of `POST /v1/images/generations`.
///
/// The decoder ignores fields that preowned does not use,
/// such as `user`, `background`, and `moderation`.
public struct ImageGenerationBody: Decodable, Sendable, Equatable {
    public var prompt: String
    public var model: String?
    public var n: Int?
    public var size: String?
    public var quality: String?
    public var style: String?
    public var responseFormat: String?
    public var outputFormat: String?
    /// OpenAI's partial-image streaming, which preowned rejects.
    public var stream: Bool?

    public init(
        prompt: String,
        model: String? = nil,
        n: Int? = nil,
        size: String? = nil,
        quality: String? = nil,
        style: String? = nil,
        responseFormat: String? = nil,
        outputFormat: String? = nil,
        stream: Bool? = nil
    ) {
        self.prompt = prompt
        self.model = model
        self.n = n
        self.size = size
        self.quality = quality
        self.style = style
        self.responseFormat = responseFormat
        self.outputFormat = outputFormat
        self.stream = stream
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case model
        case n
        case size
        case quality
        case style
        case responseFormat = "response_format"
        case outputFormat = "output_format"
        case stream
    }
}

// MARK: - Response

/// The response of every image endpoint.
public struct ImagesResponse: Codable, Sendable, Equatable {
    public var created: Int
    public var data: [ImageObject]

    public init(created: Int, data: [ImageObject]) {
        self.created = created
        self.data = data
    }
}

/// One image in an ``ImagesResponse``.
///
/// Exactly one of `b64_json` and `url` is present,
/// as the request's `response_format` chooses.
public struct ImageObject: Codable, Sendable, Equatable {
    public var b64JSON: String?
    public var url: String?

    public init(b64JSON: String? = nil, url: String? = nil) {
        self.b64JSON = b64JSON
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case b64JSON = "b64_json"
        case url
    }
}
