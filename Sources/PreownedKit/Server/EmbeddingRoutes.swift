import Hummingbird

/// `POST /v1/embeddings`.
struct EmbeddingRoutes {
    let services: ServiceRegistry
    let resolver: ModelResolver

    /// The most inputs in one request, as OpenAI allows.
    static let maximumInputCount = 2048

    func register(on router: Router<BasicRequestContext>) {
        router.post("/v1/embeddings") { request, _ in
            var request = request
            let body = try await request.decodeJSON(EmbeddingRequest.self)
            return try await embed(body)
        }
    }

    private func embed(_ body: EmbeddingRequest) async throws -> Response {
        let model = try resolver.resolve(body.model, for: .embeddings)

        let inputs: [String]
        switch body.input {
        case .tokens:
            throw OpenAIError.invalidRequest(
                "This server does not accept token arrays, "
                    + "because its models don't use OpenAI's tokenizer. Send the text as strings.",
                param: "input",
                code: "unsupported_value"
            )
        case .strings(let strings):
            inputs = strings
        }
        guard !inputs.isEmpty else {
            throw OpenAIError.invalidRequest("'input' must not be an empty array.", param: "input")
        }
        guard inputs.count <= Self.maximumInputCount else {
            throw OpenAIError.invalidRequest(
                "'input' has \(inputs.count) items, more than the limit of \(Self.maximumInputCount).",
                param: "input"
            )
        }
        if let index = inputs.firstIndex(where: \.isEmpty) {
            let location = inputs.count == 1 ? "'input'" : "'input[\(index)]'"
            throw OpenAIError.invalidRequest("\(location) must not be an empty string.", param: "input")
        }

        let useBase64: Bool
        switch body.encodingFormat {
        case nil, "float": useBase64 = false
        case "base64": useBase64 = true
        case let format?:
            throw OpenAIError.invalidRequest(
                "'\(format)' is not a supported encoding_format. Use 'float' or 'base64'.",
                param: "encoding_format",
                code: "unsupported_value"
            )
        }

        guard let service = services.embeddings else {
            throw OpenAIError.serviceUnavailable(ServiceRegistry.notImplementedReason)
        }
        if let reason = service.availability.reason {
            throw OpenAIError.serviceUnavailable(reason)
        }
        if let dimensions = body.dimensions, dimensions != service.dimensions {
            throw OpenAIError.invalidRequest(
                "The model `\(model)` makes vectors with \(service.dimensions) dimensions "
                    + "and can't shorten them. Leave out 'dimensions' or set it to \(service.dimensions).",
                param: "dimensions",
                code: "unsupported_value"
            )
        }

        let result = try await service.embed(inputs)
        let data = result.vectors.enumerated().map { index, vector in
            EmbeddingObject(index: index, embedding: EmbeddingVector(vector, base64: useBase64))
        }
        return try Response.json(
            EmbeddingResponse(data: data, model: model, usage: EmbeddingUsage(promptTokens: result.tokenCount))
        )
    }
}
