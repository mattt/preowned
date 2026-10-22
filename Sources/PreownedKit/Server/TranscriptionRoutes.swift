import Foundation
import Hummingbird

/// `POST /v1/audio/transcriptions` and `POST /v1/audio/translations`.
///
/// Both take a `multipart/form-data` body with an audio `file`.
/// The routes ignore `prompt`, `temperature`, `stream`, `chunking_strategy`, and `include[]`,
/// because SpeechTranscriber has no matching options.
struct TranscriptionRoutes {
    let services: ServiceRegistry
    let resolver: ModelResolver

    /// The largest audio file that the routes accept, as OpenAI allows: 25 MB.
    static let maximumFileSize = 25 * 1024 * 1024

    /// The largest request body: a file of the maximum size,
    /// with room for the other fields and the multipart framing.
    static let maximumBodySize = maximumFileSize + 1024 * 1024

    func register(on router: Router<BasicRequestContext>) {
        router.post("/v1/audio/transcriptions") { request, _ in
            var request = request
            let form = try await request.decodeAudioUpload()
            return try await respond(to: form, translating: false)
        }
        router.post("/v1/audio/translations") { request, _ in
            var request = request
            let form = try await request.decodeAudioUpload()
            return try await respond(to: form, translating: true)
        }
    }

    private func respond(to form: MultipartForm, translating: Bool) async throws -> Response {
        // The responses have no model field, so the route only validates the name.
        _ = try resolver.resolve(form.field("model"), for: .transcription)

        guard let file = form.file("file") else {
            throw OpenAIError.invalidRequest("Missing required parameter: 'file'.", param: "file")
        }
        guard !file.data.isEmpty else {
            throw OpenAIError.invalidRequest("The audio file is empty.", param: "file")
        }
        guard file.data.count <= Self.maximumFileSize else {
            throw OpenAIError(
                status: .contentTooLarge,
                message: "The audio file has \(file.data.count) bytes, "
                    + "more than the limit of \(Self.maximumFileSize) bytes.",
                type: "invalid_request_error",
                param: "file"
            )
        }

        let format: TranscriptionResponseFormat
        if let value = form.field("response_format"), !value.isEmpty {
            guard let parsed = TranscriptionResponseFormat(rawValue: value) else {
                let supported = TranscriptionResponseFormat.allCases.map { "'\($0.rawValue)'" }
                throw OpenAIError.invalidRequest(
                    "'\(value)' is not a supported response_format. Use one of "
                        + supported.joined(separator: ", ") + ".",
                    param: "response_format",
                    code: "unsupported_value"
                )
            }
            format = parsed
        } else {
            format = .json
        }

        let granularities = translating ? [] : try timestampGranularities(in: form)
        if !granularities.isEmpty, format != .verboseJSON {
            throw OpenAIError.invalidRequest(
                "timestamp_granularities requires response_format 'verbose_json'.",
                param: "timestamp_granularities",
                code: "unsupported_value"
            )
        }

        guard let service = services.transcription else {
            throw OpenAIError.serviceUnavailable(ServiceRegistry.notImplementedReason)
        }
        if let reason = service.availability.reason {
            throw OpenAIError.serviceUnavailable(reason)
        }

        let request = TranscriptionRequest(
            audio: file.data,
            filename: file.filename,
            language: form.field("language").flatMap { $0.isEmpty ? nil : $0 },
            prompt: form.field("prompt"),
            includeWords: granularities.contains("word")
        )
        let transcription =
            translating ? try await service.translate(request) : try await service.transcribe(request)

        switch format {
        case .json:
            let usage = translating ? nil : TranscriptionFormatter.usage(transcription)
            return try Response.json(TranscriptionJSON(text: transcription.text, usage: usage))
        case .verboseJSON:
            return try Response.json(
                TranscriptionFormatter.verbose(
                    transcription,
                    task: translating ? "translate" : "transcribe",
                    includeSegments: granularities.isEmpty || granularities.contains("segment"),
                    includeWords: granularities.contains("word"),
                    includeUsage: !translating
                )
            )
        case .text:
            return .plainText(TranscriptionFormatter.text(transcription))
        case .srt:
            return .plainText(TranscriptionFormatter.srt(transcription))
        case .vtt:
            return .plainText(TranscriptionFormatter.vtt(transcription))
        }
    }

    /// The values of `timestamp_granularities[]`,
    /// which clients send as repeated fields.
    private func timestampGranularities(in form: MultipartForm) throws -> Set<String> {
        let parts = form.files("timestamp_granularities[]") + form.files("timestamp_granularities")
        var values: Set<String> = []
        for part in parts {
            let value = String(decoding: part.data, as: UTF8.self)
            guard value == "word" || value == "segment" else {
                throw OpenAIError.invalidRequest(
                    "'\(value)' is not a supported timestamp granularity. Use 'word' or 'segment'.",
                    param: "timestamp_granularities",
                    code: "unsupported_value"
                )
            }
            values.insert(value)
        }
        return values
    }
}

extension Request {
    /// Collects and parses a `multipart/form-data` body of an audio upload.
    fileprivate mutating func decodeAudioUpload() async throws -> MultipartForm {
        try requireMediaType("multipart/form-data")
        let contentType = headers[.contentType] ?? ""
        let buffer: ByteBuffer
        do {
            buffer = try await collectBody(upTo: TranscriptionRoutes.maximumBodySize)
        } catch {
            throw OpenAIError(
                status: .contentTooLarge,
                message: "The request body is larger than \(TranscriptionRoutes.maximumBodySize) bytes. "
                    + "Audio files can have at most \(TranscriptionRoutes.maximumFileSize) bytes.",
                type: "invalid_request_error"
            )
        }
        return try MultipartForm(contentType: contentType, body: Data(buffer: buffer))
    }
}

extension Response {
    /// A 200 response with a UTF-8 text body.
    fileprivate static func plainText(_ text: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: text))
        )
    }
}
