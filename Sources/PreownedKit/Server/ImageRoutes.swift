import Foundation
import Hummingbird
import ImageIO

/// `POST /v1/images/generations`, `POST /v1/images/edits`,
/// and `POST /v1/images/variations`.
///
/// Every request goes through one ``GenerationQueue``,
/// so the service makes one generation at a time.
/// `size` is a hint that a service may pass to Image Playground;
/// the routes do not resample images.
/// `quality` is accepted and ignored.
struct ImageRoutes {
    let services: ServiceRegistry
    let resolver: ModelResolver
    let queue: GenerationQueue

    func register(on router: Router<BasicRequestContext>) {
        router.post("/v1/images/generations") { request, _ in
            var request = request
            let body = try await request.decodeJSON(ImageGenerationBody.self)
            return try await generate(
                ImageParameters(
                    model: body.model,
                    prompt: body.prompt,
                    n: body.n,
                    size: body.size,
                    style: body.style,
                    responseFormat: body.responseFormat
                ),
                sourceImage: nil
            )
        }

        router.post("/v1/images/edits") { request, _ in
            var request = request
            let form = try await request.multipartForm()
            if form.file("mask") != nil || form.field("mask") != nil {
                throw OpenAIError.invalidRequest(
                    "Image Playground does not support masks. Send the image and a prompt without 'mask'.",
                    param: "mask",
                    code: "unsupported_parameter"
                )
            }
            let parameters = try ImageParameters(form: form)
            guard let prompt = parameters.prompt, !prompt.isEmpty else {
                throw OpenAIError.invalidRequest(
                    "Missing required parameter: 'prompt'.",
                    param: "prompt",
                    code: "missing_required_parameter"
                )
            }
            return try await generate(parameters, sourceImage: try Self.sourceImage(in: form))
        }

        router.post("/v1/images/variations") { request, _ in
            var request = request
            let form = try await request.multipartForm()
            var parameters = try ImageParameters(form: form)
            // OpenAI's variations endpoint has no prompt.
            parameters.prompt = nil
            return try await generate(parameters, sourceImage: try Self.sourceImage(in: form))
        }
    }

    private func generate(_ parameters: ImageParameters, sourceImage: Data?) async throws -> Response {
        _ = try resolver.resolve(parameters.model, for: .images)
        let count = try ImageCount.validate(parameters.n)
        let format = try ImageResponseFormat(parsing: parameters.responseFormat)
        let size = try ImageSize(parsing: parameters.size)
        let prompt = parameters.prompt ?? ""
        if sourceImage == nil, prompt.isEmpty {
            throw OpenAIError.invalidRequest(
                "Missing required parameter: 'prompt'.",
                param: "prompt",
                code: "missing_required_parameter"
            )
        }

        guard let service = services.images else {
            throw OpenAIError.serviceUnavailable(ServiceRegistry.notImplementedReason)
        }
        if let reason = service.availability.reason {
            throw OpenAIError.serviceUnavailable(reason)
        }
        guard count <= service.maximumCount else {
            throw OpenAIError.invalidRequest(
                "Invalid value for 'n': \(count). This image mode creates at most \(service.maximumCount) images "
                    + "in one request, because each image waits for someone to accept it.",
                param: "n",
                code: "invalid_value"
            )
        }
        let style = try ImageStyleMapping.resolve(parameters.style, available: service.availableStyles)

        let request = ImageGenerationRequest(
            prompt: prompt,
            sourceImage: sourceImage,
            count: count,
            style: style,
            size: size
        )
        let images = try await queue.run { try await service.generateImages(request) }
        guard !images.isEmpty else {
            throw OpenAIError.server("Image Playground returned no images.")
        }

        let data = images.map { image in
            let base64 = image.pngData.base64EncodedString()
            return switch format {
            case .b64JSON: ImageObject(b64JSON: base64)
            case .url: ImageObject(url: "data:image/png;base64,\(base64)")
            }
        }
        return try Response.json(ImagesResponse(created: Int(Date().timeIntervalSince1970), data: data))
    }

    /// The one source image of an edit or a variation,
    /// from `image` or OpenAI's `image[]` array.
    private static func sourceImage(in form: MultipartForm) throws -> Data {
        let files = form.files("image") + form.files("image[]")
        guard let file = files.first else {
            throw OpenAIError.invalidRequest(
                "Missing required parameter: 'image'.",
                param: "image",
                code: "missing_required_parameter"
            )
        }
        guard files.count == 1 else {
            throw OpenAIError.invalidRequest(
                "Image Playground accepts one source image, but the request has \(files.count).",
                param: "image",
                code: "invalid_value"
            )
        }
        guard let source = CGImageSourceCreateWithData(file.data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw OpenAIError.invalidRequest(
                "Invalid image file. Send a PNG, JPEG, HEIC, or another format that ImageIO can read.",
                param: "image",
                code: "invalid_image"
            )
        }
        return file.data
    }
}

/// The parameters that every image endpoint shares.
struct ImageParameters {
    var model: String?
    var prompt: String?
    var n: Int?
    var size: String?
    var style: String?
    var responseFormat: String?

    init(
        model: String?,
        prompt: String?,
        n: Int?,
        size: String?,
        style: String?,
        responseFormat: String?
    ) {
        self.model = model
        self.prompt = prompt
        self.n = n
        self.size = size
        self.style = style
        self.responseFormat = responseFormat
    }

    /// Reads the parameters from multipart fields.
    init(form: MultipartForm) throws {
        var n: Int?
        if let value = form.field("n") {
            guard let parsed = Int(value.trimmingCharacters(in: .whitespaces)) else {
                throw OpenAIError.invalidRequest(
                    "Invalid type for 'n': expected an integer, but got '\(value)'.",
                    param: "n",
                    code: "invalid_type"
                )
            }
            n = parsed
        }
        self.init(
            model: form.field("model"),
            prompt: form.field("prompt"),
            n: n,
            size: form.field("size"),
            style: form.field("style"),
            responseFormat: form.field("response_format")
        )
    }
}

extension Request {
    /// Reads and parses a `multipart/form-data` body.
    fileprivate mutating func multipartForm() async throws -> MultipartForm {
        let buffer: ByteBuffer
        do {
            buffer = try await collectBody(upTo: PreownedServer.maximumBodySize)
        } catch {
            throw OpenAIError(
                status: .contentTooLarge,
                message: "The request body is larger than \(PreownedServer.maximumBodySize) bytes.",
                type: "invalid_request_error"
            )
        }
        return try MultipartForm(contentType: headers[.contentType] ?? "", body: Data(buffer: buffer))
    }
}
