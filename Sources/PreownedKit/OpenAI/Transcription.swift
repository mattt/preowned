import Foundation

/// The `response_format` of a transcription or translation.
public enum TranscriptionResponseFormat: String, Sendable, CaseIterable {
    case json
    case text
    case srt
    case verboseJSON = "verbose_json"
    case vtt
}

/// The `json` response of a transcription or translation.
public struct TranscriptionJSON: Codable, Sendable, Equatable {
    public var text: String
    public var usage: TranscriptionUsage?

    public init(text: String, usage: TranscriptionUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

/// Usage for a transcription, which OpenAI reports in seconds of audio for `whisper-1`.
public struct TranscriptionUsage: Codable, Sendable, Equatable {
    public var type: String
    public var seconds: Int

    public init(seconds: Int) {
        self.type = "duration"
        self.seconds = seconds
    }
}

/// The `verbose_json` response of a transcription or translation.
public struct VerboseTranscription: Codable, Sendable, Equatable {
    /// A segment with Whisper's fields.
    ///
    /// Speech doesn't produce Whisper's token IDs or decoder statistics,
    /// so `seek`, `tokens`, `temperature`, and `no_speech_prob` are fixed placeholders.
    /// `avg_logprob` is the natural logarithm of the segment's mean word confidence,
    /// and `compression_ratio` is computed from the text as Whisper does.
    /// Typed clients need these fields to decode a segment.
    public struct Segment: Codable, Sendable, Equatable {
        public var id: Int
        public var seek: Int
        public var start: Double
        public var end: Double
        public var text: String
        public var tokens: [Int]
        public var temperature: Double
        public var avgLogprob: Double
        public var compressionRatio: Double
        public var noSpeechProb: Double

        enum CodingKeys: String, CodingKey {
            case id, seek, start, end, text, tokens, temperature
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
            case noSpeechProb = "no_speech_prob"
        }
    }

    public struct Word: Codable, Sendable, Equatable {
        public var word: String
        public var start: Double
        public var end: Double
    }

    public var task: String
    public var language: String
    public var duration: Double
    public var text: String
    public var segments: [Segment]?
    public var words: [Word]?
    public var usage: TranscriptionUsage?
}

// MARK: - Formatting

/// Formats a transcription in each `response_format`.
enum TranscriptionFormatter {
    /// The English name of a language, lowercased as Whisper reports it, such as `english`.
    static func languageName(_ identifier: String?) -> String {
        guard let identifier,
            let code = Locale(identifier: identifier).language.languageCode?.identifier,
            let name = Locale(identifier: "en").localizedString(forLanguageCode: code)
        else {
            return "unknown"
        }
        return name.lowercased()
    }

    /// The seconds of audio, rounded up, for usage.
    static func usage(_ transcription: Transcription) -> TranscriptionUsage? {
        transcription.duration.map { TranscriptionUsage(seconds: Int($0.rounded(.up))) }
    }

    static func verbose(
        _ transcription: Transcription,
        task: String,
        includeSegments: Bool,
        includeWords: Bool,
        includeUsage: Bool
    ) -> VerboseTranscription {
        let segments = transcription.segments.enumerated().map { index, segment in
            VerboseTranscription.Segment(
                id: index,
                seek: 0,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                tokens: [],
                temperature: 0,
                avgLogprob: segment.confidence.map { log(max($0, 1e-6)) } ?? 0,
                compressionRatio: compressionRatio(segment.text),
                noSpeechProb: 0
            )
        }
        let words = transcription.words.map {
            VerboseTranscription.Word(word: $0.word, start: $0.start, end: $0.end)
        }
        return VerboseTranscription(
            task: task,
            language: languageName(transcription.language),
            duration: transcription.duration ?? transcription.segments.last?.end ?? 0,
            text: transcription.text,
            segments: includeSegments ? segments : nil,
            words: includeWords ? words : nil,
            usage: includeUsage ? usage(transcription) : nil
        )
    }

    /// The ratio of a text's UTF-8 size to its zlib-compressed size, as Whisper computes it.
    static func compressionRatio(_ text: String) -> Double {
        let data = Data(text.utf8)
        guard !data.isEmpty, let compressed = try? (data as NSData).compressed(using: .zlib),
            compressed.length > 0
        else {
            return 0
        }
        return Double(data.count) / Double(compressed.length)
    }

    /// The text with a trailing newline, as OpenAI returns it.
    static func text(_ transcription: Transcription) -> String {
        transcription.text + "\n"
    }

    /// SubRip subtitles, with one cue for each segment.
    static func srt(_ transcription: Transcription) -> String {
        cues(transcription).enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> "
                + "\(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
        }
        .joined(separator: "\n")
    }

    /// WebVTT subtitles, with one cue for each segment.
    static func vtt(_ transcription: Transcription) -> String {
        "WEBVTT\n\n"
            + cues(transcription).map { cue in
                "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
            }
            .joined(separator: "\n")
    }

    private static func cues(_ transcription: Transcription) -> [Transcription.Segment] {
        transcription.segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Transcription.Segment(start: segment.start, end: segment.end, text: text)
        }
    }

    /// A timestamp such as `00:01:02,345`.
    static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let wholeSeconds = milliseconds / 1000 % 60
        let fraction = milliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, wholeSeconds, separator, fraction)
    }
}
