import AVFoundation
import Foundation
import NaturalLanguage
import Synchronization

/// A speech service backed by `AVSpeechSynthesizer`,
/// which writes audio buffers instead of playing them.
///
/// ``VoiceCatalog`` maps OpenAI voice names to system voices,
/// and its ``VoiceCatalog/rate(forSpeed:)`` maps `speed` to the utterance rate.
/// The service resamples the synthesizer's output to 24 kHz mono, as OpenAI's audio is,
/// and encodes WAV and PCM itself, AAC and FLAC with `AVAudioFile`,
/// and Opus with `AVAudioConverter` in an Ogg container that ``OggOpusMuxer`` writes.
public struct SystemSpeechService: SpeechService, InventoryReporting {
    public init() {}

    /// The sample rate of every format, as OpenAI uses.
    static let sampleRate = 24_000.0

    public var availability: ServiceAvailability {
        AVSpeechSynthesisVoice.speechVoices().isEmpty
            ? .unavailable(reason: "This Mac has no speech synthesis voices.")
            : .available
    }

    public var supportedFormats: [SpeechAudioFormat] {
        SpeechAudioFormat.allCases
    }

    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let language = Self.dominantLanguage(of: request.input)
        guard
            let voice = VoiceCatalog.voice(
                named: request.voice,
                language: language,
                in: Self.installedVoices(),
                defaultEnglishIdentifier: AVSpeechSynthesisVoice(language: "en-US")?.identifier
            )
        else {
            let names = VoiceCatalog.openAIVoices.map { "'\($0)'" }.joined(separator: ", ")
            throw OpenAIError.invalidRequest(
                "'\(request.voice)' is not a voice on this server. "
                    + "Use one of \(names), or the name or identifier of an installed system voice.",
                param: "voice",
                code: "invalid_value"
            )
        }

        let rendered = try await SpeechRenderer.render(
            request.input,
            voiceIdentifier: voice.identifier,
            rate: VoiceCatalog.rate(forSpeed: request.speed)
        )
        // Opus codes at 48 kHz, so it resamples once, from the synthesizer's rate.
        let rate = request.format == .opus ? AudioEncoding.opusSampleRate : Self.sampleRate
        let samples = try AudioEncoding.resample(rendered.samples, from: rendered.sampleRate, to: rate)
        let data = try AudioEncoding.encode(samples, sampleRate: rate, as: request.format)
        return SynthesizedSpeech(data: data, contentType: request.format.contentType)
    }

    public func inventoryDetails() async -> [String] {
        let voices = Self.installedVoices()
        let fallback = AVSpeechSynthesisVoice(language: "en-US")?.identifier
        let qualities = [1: "default", 2: "enhanced", 3: "premium"]
        return VoiceCatalog.openAIVoices.map { name in
            guard
                let voice = VoiceCatalog.voice(
                    named: name, language: nil, in: voices, defaultEnglishIdentifier: fallback)
            else {
                return "\(name): no voice"
            }
            return "\(name): \(voice.name) (\(voice.language), \(qualities[voice.quality] ?? "unknown") quality)"
        }
    }

    /// The installed voices, for ``VoiceCatalog``.
    static func installedVoices() -> [VoiceCatalog.Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            let gender: VoiceCatalog.Voice.Gender =
                switch voice.gender {
                case .male: .male
                case .female: .female
                default: .unspecified
                }
            return VoiceCatalog.Voice(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: voice.quality.rawValue,
                gender: gender,
                isExcluded: voice.voiceTraits.contains(.isNoveltyVoice)
                    || voice.voiceTraits.contains(.isPersonalVoice)
            )
        }
    }

    /// The dominant language of a text, such as `fr`, if the recognizer is confident.
    static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
            probability >= 0.8
        else {
            return nil
        }
        return Locale.Language(identifier: language.rawValue).languageCode?.identifier
    }
}

// MARK: - Rendering

/// Runs `AVSpeechSynthesizer`, which calls back on the main thread.
@MainActor
private enum SpeechRenderer {
    /// Mono samples and their sample rate.
    struct Rendered: Sendable {
        var samples: [Float]
        var sampleRate: Double
    }

    /// Collects the synthesizer's buffers and resumes the caller once.
    final class Collector: Sendable {
        private struct State {
            var samples: [Float] = []
            var sampleRate = 0.0
            var continuation: CheckedContinuation<Rendered, any Error>?
        }

        private let state = Mutex(State())

        func start(_ continuation: CheckedContinuation<Rendered, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            let samples = Self.monoSamples(of: buffer)
            state.withLock {
                $0.sampleRate = buffer.format.sampleRate
                $0.samples += samples
            }
        }

        func finish(_ error: (any Error)? = nil) {
            let (continuation, rendered) = state.withLock { state in
                defer { state.continuation = nil }
                return (state.continuation, Rendered(samples: state.samples, sampleRate: state.sampleRate))
            }
            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: rendered)
            }
        }

        private static func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
            let count = Int(buffer.frameLength)
            if let channel = buffer.floatChannelData?[0] {
                return Array(UnsafeBufferPointer(start: channel, count: count))
            }
            if let channel = buffer.int16ChannelData?[0] {
                return UnsafeBufferPointer(start: channel, count: count).map { Float($0) / Float(Int16.max) }
            }
            if let channel = buffer.int32ChannelData?[0] {
                return UnsafeBufferPointer(start: channel, count: count).map { Float($0) / Float(Int32.max) }
            }
            return []
        }
    }

    static func render(_ text: String, voiceIdentifier: String, rate: Float) async throws -> Rendered {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        utterance.rate = rate
        let synthesizer = AVSpeechSynthesizer()
        let collector = Collector()

        // The synthesizer reads about three words a second at the default rate,
        // so this limit is generous for the longest input.
        let timeout = Task {
            try await Task.sleep(for: .seconds(60 + text.count / 4))
            collector.finish(OpenAIError.server("Speech synthesis timed out."))
        }
        defer { timeout.cancel() }

        let rendered = try await withCheckedThrowingContinuation { continuation in
            collector.start(continuation)
            synthesizer.write(utterance) { buffer in
                guard let buffer = buffer as? AVAudioPCMBuffer else { return }
                // A buffer with no frames marks the end of the utterance.
                if buffer.frameLength == 0 {
                    collector.finish()
                } else {
                    collector.append(buffer)
                }
            }
        }
        withExtendedLifetime(synthesizer) {}
        guard rendered.sampleRate > 0, !rendered.samples.isEmpty else {
            throw OpenAIError.invalidRequest("The input has nothing to speak.", param: "input")
        }
        return rendered
    }
}

// MARK: - Encoding

/// Converts and encodes mono samples.
enum AudioEncoding {
    /// Resamples mono samples with `AVAudioConverter`.
    static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        guard inputRate != outputRate else { return samples }
        guard let input = buffer(samples, sampleRate: inputRate),
            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
            let converter = AVAudioConverter(from: input.format, to: outputFormat),
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(Double(samples.count) * outputRate / inputRate) + 1024
            )
        else {
            throw OpenAIError.server("The server could not resample the speech.")
        }
        var error: NSError?
        // The converter calls the block synchronously, during `convert`.
        var supplied = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            defer { supplied = true }
            inputStatus.pointee = supplied ? .endOfStream : .haveData
            return supplied ? nil : input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw OpenAIError.server("The server could not resample the speech: \(error?.localizedDescription ?? "")")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Encodes mono samples in a format.
    static func encode(_ samples: [Float], sampleRate: Double, as format: SpeechAudioFormat) throws -> Data {
        switch format {
        case .pcm:
            return pcm16(samples)
        case .wav:
            return wav(samples, sampleRate: sampleRate)
        case .aac:
            return try encodeWithAudioFile(
                samples,
                sampleRate: sampleRate,
                pathExtension: "aac",
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
            )
        case .flac:
            return try encodeWithAudioFile(
                samples,
                sampleRate: sampleRate,
                pathExtension: "flac",
                settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
            )
        case .opus:
            return try opus(resample(samples, from: sampleRate, to: opusSampleRate))
        }
    }

    /// The sample rate of Opus packets and Ogg Opus granule positions.
    static let opusSampleRate = 48_000.0

    /// The pre-skip to use if the encoder doesn't report its priming frames:
    /// the 6.5 ms delay of libopus at 48 kHz.
    static let defaultOpusPreSkip: UInt16 = 312

    /// Ogg Opus from mono samples at 48 kHz.
    ///
    /// AudioToolbox encodes the Opus packets,
    /// and its `primeInfo` gives the encoder's delay, which becomes the pre-skip.
    /// The OpusHead's input sample rate is 24 kHz,
    /// the rate of the other formats,
    /// so a decoder that honors it returns the same rate as they have.
    static func opus(_ samples: [Float]) throws -> Data {
        var description = AudioStreamBasicDescription(
            mSampleRate: opusSampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = buffer(samples, sampleRate: opusSampleRate),
            let outputFormat = AVAudioFormat(streamDescription: &description),
            let converter = AVAudioConverter(from: input.format, to: outputFormat)
        else {
            throw OpenAIError.server("The server could not create an Opus encoder.")
        }
        let leadingFrames = converter.primeInfo.leadingFrames
        let preSkip = leadingFrames > 0 ? UInt16(clamping: leadingFrames) : defaultOpusPreSkip
        let framesPerPacket = Int(outputFormat.streamDescription.pointee.mFramesPerPacket)

        var packets: [OggOpusMuxer.Packet] = []
        // The converter calls the block synchronously, during `convert`.
        var supplied = false
        while true {
            let output = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: 256,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 1)
            )
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                defer { supplied = true }
                inputStatus.pointee = supplied ? .endOfStream : .haveData
                return supplied ? nil : input
            }
            guard status != .error else {
                throw OpenAIError.server("The server could not encode Opus: \(error?.localizedDescription ?? "")")
            }
            for index in 0..<Int(output.packetCount) {
                guard let description = output.packetDescriptions?[index] else { continue }
                let start = Int(description.mStartOffset)
                let data = Data(bytes: output.data + start, count: Int(description.mDataByteSize))
                let frames = Int(description.mVariableFramesInPacket)
                packets.append(.init(data: data, sampleCount: frames > 0 ? frames : framesPerPacket))
            }
            if status == .endOfStream || output.packetCount == 0 {
                break
            }
        }
        let muxer = OggOpusMuxer(
            serial: UInt32.random(in: 0...UInt32.max),
            preSkip: preSkip,
            inputSampleRate: UInt32(SystemSpeechService.sampleRate)
        )
        return muxer.file(packets: packets, sampleCount: samples.count)
    }

    /// 16-bit signed little-endian samples.
    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * Float(Int16.max)).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A 16-bit mono WAV file.
    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        let pcm = pcm16(samples)
        let rate = UInt32(sampleRate)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))  // The size of the fmt chunk.
        append(UInt16(1))  // PCM.
        append(UInt16(1))  // Mono.
        append(rate)
        append(rate * 2)  // Bytes per second.
        append(UInt16(2))  // Bytes per frame.
        append(UInt16(16))  // Bits per sample.
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private static func encodeWithAudioFile(
        _ samples: [Float],
        sampleRate: Double,
        pathExtension: String,
        settings: [String: Any]
    ) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preowned-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let input = buffer(samples, sampleRate: sampleRate) else {
            throw OpenAIError.server("The server could not encode the speech.")
        }
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: input)
            file.close()
            return try Data(contentsOf: url)
        } catch {
            throw OpenAIError.server("The server could not encode the speech: \(error.localizedDescription)")
        }
    }

    private static func buffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))),
            let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
