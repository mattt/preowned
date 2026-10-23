import Hummingbird

/// `POST /v1/audio/speech`.
///
/// OpenAI's default format is MP3, which needs an external encoder.
/// Without one, `mp3` and a request without `response_format` get AAC in ADTS
/// with the honest `Content-Type: audio/aac`,
/// so that the default request works.
/// A player that trusts a `.mp3` file extension, such as `afplay`, can't open that file;
/// FFmpeg reads the content and identifies it as AAC.
/// `opus` returns Ogg Opus, as OpenAI's does.
struct SpeechRoutes {
    let services: ServiceRegistry
    let resolver: ModelResolver

    /// The longest input, as OpenAI allows.
    static let maximumInputLength = 4096

    /// The formats that the route maps to another format
    /// when the service can't make them.
    static let substitutes: [String: SpeechAudioFormat] = ["mp3": .aac]

    func register(on router: Router<BasicRequestContext>) {
        router.post("/v1/audio/speech") { request, _ in
            var request = request
            let body = try await request.decodeJSON(SpeechCreateRequest.self)
            return try await speak(body)
        }
    }

    private func speak(_ body: SpeechCreateRequest) async throws -> Response {
        _ = try resolver.resolve(body.model, for: .speech)

        guard !body.input.isEmpty else {
            throw OpenAIError.invalidRequest("'input' must not be empty.", param: "input")
        }
        guard body.input.count <= Self.maximumInputLength else {
            throw OpenAIError.invalidRequest(
                "'input' has \(body.input.count) characters, "
                    + "more than the limit of \(Self.maximumInputLength).",
                param: "input"
            )
        }
        guard !body.voice.isEmpty else {
            throw OpenAIError.invalidRequest("Missing required parameter: 'voice'.", param: "voice")
        }
        let speed = body.speed ?? 1
        guard (0.25...4).contains(speed) else {
            throw OpenAIError.invalidRequest(
                "'speed' must be from 0.25 to 4.0.",
                param: "speed",
                code: "invalid_value"
            )
        }
        if let streamFormat = body.streamFormat, streamFormat != "audio" {
            throw OpenAIError.invalidRequest(
                "stream_format '\(streamFormat)' is not supported. Use 'audio'.",
                param: "stream_format",
                code: "unsupported_value"
            )
        }

        guard let service = services.speech else {
            throw OpenAIError.serviceUnavailable(ServiceRegistry.notImplementedReason)
        }
        if let reason = service.availability.reason {
            throw OpenAIError.serviceUnavailable(reason)
        }
        let format = try format(named: body.responseFormat ?? "mp3", supported: service.supportedFormats)

        let speech = try await service.synthesize(
            SpeechRequest(input: body.input, voice: body.voice, speed: speed, format: format)
        )
        return Response(
            status: .ok,
            headers: [.contentType: speech.contentType],
            body: .init(byteBuffer: ByteBuffer(bytes: speech.data))
        )
    }

    private func format(named name: String, supported: [SpeechAudioFormat]) throws -> SpeechAudioFormat {
        if let format = SpeechAudioFormat(rawValue: name), supported.contains(format) {
            return format
        }
        if let format = Self.substitutes[name], supported.contains(format) {
            return format
        }
        let supportedNames = supported.map(\.rawValue)
        let substituted = Self.substitutes.filter { name, format in
            !supportedNames.contains(name) && supported.contains(format)
        }
        let names = supportedNames + substituted.keys.sorted()
        throw OpenAIError.invalidRequest(
            "response_format '\(name)' is not supported on this server. Use one of "
                + names.map { "'\($0)'" }.joined(separator: ", ") + ".",
            param: "response_format",
            code: "unsupported_value"
        )
    }
}
