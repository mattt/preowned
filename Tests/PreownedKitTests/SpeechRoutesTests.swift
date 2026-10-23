import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PreownedKit

@Suite("Speech")
struct SpeechRoutesTests {
    let service = FakeSpeechService()
    var services: ServiceRegistry { ServiceRegistry(speech: service) }

    @Test(
        "Each response_format maps to a format with an honest Content-Type",
        arguments: [
            (#""response_format": "wav", "#, SpeechAudioFormat.wav, "audio/wav"),
            (#""response_format": "pcm", "#, .pcm, "audio/pcm"),
            (#""response_format": "aac", "#, .aac, "audio/aac"),
            (#""response_format": "flac", "#, .flac, "audio/flac"),
            (#""response_format": "opus", "#, .opus, "audio/ogg"),
            (#""response_format": "mp3", "#, .aac, "audio/aac"),
            ("", .aac, "audio/aac"),
        ]
    )
    func formats(field: String, format: SpeechAudioFormat, contentType: String) async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/audio/speech",
                json: #"{"model": "tts-1", "input": "Hello", \#(field)"voice": "alloy"}"#
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == contentType)
                #expect(response.text == "audio:Hello")
            }
        }
        #expect(service.lastRequest == SpeechRequest(input: "Hello", voice: "alloy", speed: 1, format: format))
    }

    @Test("speed passes through, and instructions are ignored")
    func speed() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/audio/speech",
                json: #"{"input": "Hi", "voice": "nova", "speed": 1.5, "instructions": "Sound cheerful."}"#
            ) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(service.lastRequest?.speed == 1.5)
        #expect(service.lastRequest?.voice == "nova")
    }

    @Test(
        "Invalid requests return 400 with the parameter",
        arguments: [
            (#"{"input": "", "voice": "alloy"}"#, "input"),
            (#"{"input": "Hi", "voice": ""}"#, "voice"),
            (#"{"input": "Hi", "voice": "alloy", "speed": 0.1}"#, "speed"),
            (#"{"input": "Hi", "voice": "alloy", "speed": 4.5}"#, "speed"),
            (#"{"input": "Hi", "voice": "alloy", "response_format": "ogg"}"#, "response_format"),
            (#"{"input": "Hi", "voice": "alloy", "stream_format": "sse"}"#, "stream_format"),
        ]
    )
    func invalidRequests(json: String, param: String) async throws {
        try await withServer(services) { client in
            try await client.post("/v1/audio/speech", json: json) { response in
                #expect(response.status == .badRequest)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                #expect(error.param == param)
            }
        }
    }

    @Test("Missing fields and input over 4096 characters return 400")
    func limits() async throws {
        let long = String(repeating: "a", count: 4097)
        try await withServer(services) { client in
            try await client.post("/v1/audio/speech", json: #"{"input": "\#(long)", "voice": "alloy"}"#) {
                response in
                #expect(response.status == .badRequest)
                #expect(response.error?.param == "input")
            }
            try await client.post("/v1/audio/speech", json: #"{"input": "Hi"}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.message == "Missing required parameter: 'voice'.")
            }
        }
    }

    @Test("A format that the service can't make is a 400")
    func unsupportedFormat() async throws {
        let services = ServiceRegistry(speech: FakeSpeechService(supportedFormats: [.wav, .pcm]))
        try await withServer(services) { client in
            try await client.post("/v1/audio/speech", json: #"{"input": "Hi", "voice": "alloy"}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.param == "response_format")
            }
        }
    }

    @Test("An unavailable service returns 503 server_error")
    func unavailable() async throws {
        let services = ServiceRegistry(speech: FakeSpeechService(availability: .unavailable(reason: "No voices.")))
        try await withServer(services) { client in
            try await client.post("/v1/audio/speech", json: #"{"input": "Hi", "voice": "alloy"}"#) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.error?.type == "server_error")
                #expect(response.error?.code == "service_unavailable")
                #expect(response.error?.message == "No voices.")
            }
        }
    }
}

@Suite("Voices and audio encoding")
struct VoiceCatalogTests {
    typealias Voice = VoiceCatalog.Voice

    let voices = [
        Voice(identifier: "compact.en-US.Samantha", name: "Samantha", language: "en-US", gender: .female),
        Voice(identifier: "premium.en-US.Ava", name: "Ava", language: "en-US", quality: 3, gender: .female),
        Voice(identifier: "compact.en-AU.Ava", name: "Ava", language: "en-AU", gender: .female),
        Voice(identifier: "enhanced.en-GB.Daniel", name: "Daniel", language: "en-GB", quality: 2, gender: .male),
        Voice(identifier: "eloquence.en-US.Reed", name: "Reed", language: "en-US"),
        Voice(identifier: "eloquence.fr-FR.Reed", name: "Reed", language: "fr-FR"),
        Voice(identifier: "compact.fr-FR.Thomas", name: "Thomas", language: "fr-FR", gender: .male),
        Voice(identifier: "compact.fr-CA.Amelie", name: "Amélie", language: "fr-CA", gender: .female),
        Voice(identifier: "novelty.Bells", name: "Bells", language: "en-US", isExcluded: true),
        Voice(identifier: "compact.en-US.Fred", name: "Fred", language: "en-US", gender: .male),
    ]

    func voice(_ name: String, language: String? = nil) -> String? {
        VoiceCatalog.voice(
            named: name,
            language: language,
            in: voices,
            defaultEnglishIdentifier: "compact.en-US.Samantha"
        )?.identifier
    }

    @Test("OpenAI voices map to the first installed name in its best quality")
    func openAIVoices() {
        #expect(voice("alloy") == "compact.en-US.Samantha")
        #expect(voice("coral") == "premium.en-US.Ava")
        #expect(voice("fable") == "enhanced.en-GB.Daniel")
        #expect(voice("ash") == "eloquence.en-US.Reed")
        #expect(voice("verse") == "compact.en-US.Fred")
        #expect(voice("ALLOY") == "compact.en-US.Samantha")
    }

    @Test("Without a listed name, the catalog picks the same gender, then the default")
    func fallbacks() {
        // No Oliver, Arthur, or Grandpa: the best male English voice is Daniel.
        #expect(voice("ballad") == "enhanced.en-GB.Daniel")
        // No Zoe, Joelle, or Moira: the best female English voice is Ava.
        #expect(voice("shimmer") == "premium.en-US.Ava")
        let onlyNovelty = [voices[0], voices[8]]
        let fallback = VoiceCatalog.voice(
            named: "onyx",
            language: nil,
            in: onlyNovelty,
            defaultEnglishIdentifier: "compact.en-US.Samantha"
        )
        #expect(fallback?.identifier == "compact.en-US.Samantha")
    }

    @Test("Text in another language uses a voice for that language")
    func otherLanguages() {
        #expect(voice("ash", language: "fr") == "eloquence.fr-FR.Reed")
        #expect(voice("echo", language: "fr") == "compact.fr-FR.Thomas")
        #expect(voice("nova", language: "fr") == "compact.fr-CA.Amelie")
        // No voice for Japanese: the English mapping applies.
        #expect(voice("alloy", language: "ja") == "compact.en-US.Samantha")
    }

    @Test("System voices by identifier or name, and unknown names")
    func systemVoices() {
        #expect(voice("compact.fr-FR.Thomas") == "compact.fr-FR.Thomas")
        #expect(voice("thomas") == "compact.fr-FR.Thomas")
        #expect(voice("Reed") == "eloquence.en-US.Reed")
        #expect(voice("bells") == nil)
        #expect(voice("nobody") == nil)
    }

    @Test("Speed maps to the measured rate curve and clamps at its ends")
    func rates() {
        #expect(VoiceCatalog.rate(forSpeed: 1) == 0.5)
        #expect(VoiceCatalog.rate(forSpeed: 0.25) == 0)
        #expect(VoiceCatalog.rate(forSpeed: 4) > 0.99)
        #expect(abs(VoiceCatalog.rate(forSpeed: 2.11) - 0.7) < 0.0001)
        let rates = stride(from: 0.25, through: 4, by: 0.25).map(VoiceCatalog.rate(forSpeed:))
        #expect(rates == rates.sorted())
    }

    @Test("WAV has a 44-byte header with the sample rate and 16-bit samples")
    func wav() {
        let data = AudioEncoding.wav([0, 1, -1, 0.5], sampleRate: 24_000)
        #expect(data.count == 44 + 8)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data[8..<16] == Data("WAVEfmt ".utf8))
        #expect(data[24..<28] == Data([0xC0, 0x5D, 0, 0]))
        #expect(data[36..<40] == Data("data".utf8))
        #expect(data.suffix(8) == Data([0, 0, 0xFF, 0x7F, 0x01, 0x80, 0x00, 0x40]))
    }

    @Test("Opus is Ogg with the encoder's pre-skip and a final granule position at the audio's end")
    func opus() throws {
        let tone = (0..<48_000).map { Float(sin(Double($0) * 0.05) * 0.5) }
        let data = try AudioEncoding.encode(tone, sampleRate: 48_000, as: .opus)
        let pages = try OggOpusMuxerTests.pages(in: data)
        try #require(pages.count >= 3)
        #expect(pages[0].body.prefix(8) == Data("OpusHead".utf8))
        let preSkip = Int(pages[0].body[10]) | Int(pages[0].body[11]) << 8
        #expect(preSkip > 0)
        #expect(pages[1].body.prefix(8) == Data("OpusTags".utf8))
        #expect(pages.last?.flags == 0x04)
        #expect(pages.last?.granulePosition == Int64(preSkip + 48_000))
        #expect(Set(pages.map(\.serial)).count == 1)
        let positions = pages.dropFirst(2).map(\.granulePosition)
        #expect(positions == positions.sorted() && Set(positions).count == positions.count)
    }

    @Test("PCM clamps samples and resampling changes the length by the ratio")
    func pcmAndResampling() throws {
        #expect(AudioEncoding.pcm16([2, -2]) == Data([0xFF, 0x7F, 0x01, 0x80]))
        let tone = (0..<22_050).map { Float(sin(Double($0) * 0.1)) }
        let resampled = try AudioEncoding.resample(tone, from: 22_050, to: 24_000)
        #expect(abs(resampled.count - 24_000) < 200)
    }
}
