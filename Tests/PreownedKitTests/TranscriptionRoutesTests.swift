import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PreownedKit

@Suite("Transcriptions and translations")
struct TranscriptionRoutesTests {
    let service = FakeTranscriptionService()
    var services: ServiceRegistry { ServiceRegistry(transcription: service) }
    let upload = MultipartBody().file("file").field("model", "whisper-1")

    @Test("json returns the text and the seconds of audio")
    func json() async throws {
        try await withServer(services) { client in
            try await client.post("/v1/audio/transcriptions", multipart: upload) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let body = try response.decode(TranscriptionJSON.self)
                #expect(body.text == "Hello from the lot. We have GPT at home.")
                #expect(body.usage == TranscriptionUsage(seconds: 2))
                #expect(response.text.contains(#""type":"duration""#))
            }
        }
        let (request, translated) = try #require(service.lastRequest)
        #expect(!translated)
        #expect(request.audio == Data("RIFF".utf8))
        #expect(request.filename == "speech.wav")
        #expect(request.language == nil)
        #expect(!request.includeWords)
    }

    @Test("language and prompt pass through to the service")
    func languageAndPrompt() async throws {
        let body = upload.field("language", "fr").field("prompt", "Car talk.")
        try await withServer(services) { client in
            try await client.post("/v1/audio/transcriptions", multipart: body) { response in
                #expect(response.status == .ok)
            }
        }
        let (request, _) = try #require(service.lastRequest)
        #expect(request.language == "fr")
        #expect(request.prompt == "Car talk.")
    }

    @Test("text, srt, and vtt return plain text")
    func textFormats() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: upload.field("response_format", "text")
            ) { response in
                #expect(response.headers[.contentType] == "text/plain; charset=utf-8")
                #expect(response.text == "Hello from the lot. We have GPT at home.\n")
            }
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: upload.field("response_format", "srt")
            ) { response in
                #expect(
                    response.text
                        == """
                        1
                        00:00:00,000 --> 00:00:01,140
                        Hello from the lot.

                        2
                        00:00:01,140 --> 00:00:01,720
                        We have GPT at home.

                        """
                )
            }
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: upload.field("response_format", "vtt")
            ) { response in
                #expect(
                    response.text
                        == """
                        WEBVTT

                        00:00:00.000 --> 00:00:01.140
                        Hello from the lot.

                        00:00:01.140 --> 00:00:01.720
                        We have GPT at home.

                        """
                )
            }
        }
    }

    @Test("verbose_json has the language name, duration, and Whisper's segment fields")
    func verbose() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: upload.field("response_format", "verbose_json")
            ) { response in
                let body = try response.decode(VerboseTranscription.self)
                #expect(body.task == "transcribe")
                #expect(body.language == "english")
                #expect(body.duration == 1.72)
                #expect(body.words == nil)
                #expect(body.usage == TranscriptionUsage(seconds: 2))
                let segments = try #require(body.segments)
                #expect(segments.map(\.id) == [0, 1])
                #expect(segments.map(\.start) == [0, 1.14])
                #expect(segments[1].text == " We have GPT at home.")
                #expect(abs(segments[0].avgLogprob - log(0.5)) < 0.0001)
                #expect(segments[1].avgLogprob == 0)
                #expect(segments[0].compressionRatio > 0)
                #expect(response.text.contains(#""no_speech_prob":0"#))
            }
        }
        #expect(service.lastRequest?.0.includeWords == false)
    }

    @Test("Word granularity adds words, and word alone leaves out segments")
    func wordGranularity() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: upload.field("response_format", "verbose_json")
                    .field("timestamp_granularities[]", "word")
                    .field("timestamp_granularities[]", "segment")
            ) { response in
                let body = try response.decode(VerboseTranscription.self)
                #expect(body.words?.map(\.word) == ["Hello", "from"])
                #expect(body.segments?.count == 2)
            }
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: upload.field("response_format", "verbose_json")
                    .field("timestamp_granularities[]", "word")
            ) { response in
                let body = try response.decode(VerboseTranscription.self)
                #expect(body.words?.count == 2)
                #expect(body.segments == nil)
            }
        }
        #expect(service.lastRequest?.0.includeWords == true)
    }

    @Test(
        "Invalid uploads return 400 with the parameter",
        arguments: [
            (MultipartBody().field("model", "whisper-1"), "file"),
            (MultipartBody().file("file", data: Data()), "file"),
            (MultipartBody().file("file").field("response_format", "diarized_json"), "response_format"),
            (
                MultipartBody().file("file").field("timestamp_granularities[]", "word"),
                "timestamp_granularities"
            ),
            (
                MultipartBody().file("file").field("response_format", "verbose_json")
                    .field("timestamp_granularities[]", "sentence"),
                "timestamp_granularities"
            ),
        ]
    )
    func invalidUploads(body: MultipartBody, param: String) async throws {
        try await withServer(services) { client in
            try await client.post("/v1/audio/transcriptions", multipart: body) { response in
                #expect(response.status == .badRequest)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                #expect(error.param == param)
            }
        }
    }

    @Test("A body that is not multipart, or is malformed, returns 400")
    func notMultipart() async throws {
        try await withServer(services) { client in
            try await client.post("/v1/audio/transcriptions", json: #"{"file": "x"}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.type == "invalid_request_error")
            }
            try await client.execute(
                uri: "/v1/audio/transcriptions",
                method: .post,
                headers: [.contentType: MultipartBody.contentType],
                body: ByteBuffer(string: "--preowned-test-boundary\r\nno headers")
            ) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/v1/audio/transcriptions", method: .post) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("A file over 25 MB returns 413")
    func fileTooLarge() async throws {
        let body = MultipartBody().file("file", data: Data(count: TranscriptionRoutes.maximumFileSize + 1))
        try await withServer(services) { client in
            try await client.post("/v1/audio/transcriptions", multipart: body) { response in
                #expect(response.status == .contentTooLarge)
                #expect(response.error?.param == "file")
            }
        }
    }

    @Test("A file of exactly 25 MB is accepted")
    func fileAtLimit() async throws {
        let body = MultipartBody().file("file", data: Data(count: TranscriptionRoutes.maximumFileSize))
        try await withServer(services) { client in
            try await client.post("/v1/audio/transcriptions", multipart: body) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("An unavailable service returns 503, and service errors keep their status")
    func errors() async throws {
        let unavailable = ServiceRegistry(
            transcription: FakeTranscriptionService(availability: .unavailable(reason: "No speech."))
        )
        try await withServer(unavailable) { client in
            try await client.post("/v1/audio/transcriptions", multipart: upload) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.error?.type == "server_error")
                #expect(response.error?.code == "service_unavailable")
            }
        }
        let missingLocale = ServiceRegistry(
            transcription: FakeTranscriptionService(result: .failure(.serviceUnavailable("Install French.")))
        )
        try await withServer(missingLocale) { client in
            try await client.post("/v1/audio/translations", multipart: upload) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.error?.message == "Install French.")
            }
        }
    }

    @Test("Translations call translate and report English without usage")
    func translation() async throws {
        try await withServer(services) { client in
            try await client.post("/v1/audio/translations", multipart: upload) { response in
                let body = try response.decode(TranscriptionJSON.self)
                #expect(body.text == "Hello from the lot. We have GPT at home.")
                #expect(body.usage == nil)
            }
            try await client.post(
                "/v1/audio/translations",
                multipart: upload.field("response_format", "verbose_json")
                    .field("timestamp_granularities[]", "word")
            ) { response in
                let body = try response.decode(VerboseTranscription.self)
                #expect(body.task == "translate")
                #expect(body.language == "english")
                #expect(body.words == nil)
            }
        }
        #expect(service.lastRequest?.translated == true)
    }

    @Test("Strict mode rejects other model names")
    func strictModels() async throws {
        try await withServer(services, configuration: ServerConfiguration(strictModels: true)) { client in
            try await client.post("/v1/audio/transcriptions", multipart: upload) { response in
                #expect(response.status == .notFound)
                #expect(response.error?.code == "model_not_found")
            }
            try await client.post(
                "/v1/audio/transcriptions",
                multipart: MultipartBody().file("file").field("model", "apple-speech-transcriber")
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}

@Suite("Transcription formatting and locales")
struct TranscriptionFormattingTests {
    @Test("Timestamps carry hours and round to milliseconds")
    func timestamps() {
        #expect(TranscriptionFormatter.timestamp(0, separator: ",") == "00:00:00,000")
        #expect(TranscriptionFormatter.timestamp(3725.4567, separator: ".") == "01:02:05.457")
        #expect(TranscriptionFormatter.timestamp(-1, separator: ",") == "00:00:00,000")
    }

    @Test("Language names are lowercased English names")
    func languageNames() {
        #expect(TranscriptionFormatter.languageName("en-US") == "english")
        #expect(TranscriptionFormatter.languageName("fr") == "french")
        #expect(TranscriptionFormatter.languageName(nil) == "unknown")
    }

    @Test("Empty segments are left out of subtitles")
    func emptyCues() {
        let transcription = Transcription(
            text: "Hi",
            segments: [.init(start: 0, end: 1, text: "  "), .init(start: 1, end: 2, text: " Hi ")]
        )
        #expect(TranscriptionFormatter.srt(transcription) == "1\n00:00:01,000 --> 00:00:02,000\nHi\n")
    }

    let installed = ["en_US", "en_GB", "en_AU", "fr_CA"].map(Locale.init(identifier:))
    let supported = ["en_US", "en_GB", "en_AU", "en_NZ", "fr_FR", "fr_CA", "de_DE", "de_CH"]
        .map(Locale.init(identifier:))

    func resolve(_ language: String?, current: String = "en_US") -> SpeechTranscriptionService.LocaleResolution {
        SpeechTranscriptionService.resolveLocale(
            language,
            current: Locale(identifier: current),
            installed: installed,
            supported: supported
        )
    }

    @Test("Locales resolve by region, then by the current or likely region, installed first")
    func locales() {
        #expect(resolve(nil) == .installed(Locale(identifier: "en_US")))
        #expect(resolve(nil, current: "en_GB") == .installed(Locale(identifier: "en_GB")))
        #expect(resolve("en") == .installed(Locale(identifier: "en_US")))
        #expect(resolve("en", current: "en_AU") == .installed(Locale(identifier: "en_AU")))
        #expect(resolve("en-GB") == .installed(Locale(identifier: "en_GB")))
        #expect(resolve("en-NZ") == .notInstalled(Locale(identifier: "en_NZ")))
        #expect(resolve("fr") == .installed(Locale(identifier: "fr_CA")))
        #expect(resolve("fr-FR") == .notInstalled(Locale(identifier: "fr_FR")))
        #expect(resolve("de") == .notInstalled(Locale(identifier: "de_DE")))
        #expect(resolve("ja") == .unsupported)
        #expect(resolve("english") == .unsupported)
    }
}
