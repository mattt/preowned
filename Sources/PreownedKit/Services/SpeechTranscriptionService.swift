import AVFoundation
import Foundation
import Speech
import Translation

/// A transcription service backed by `SpeechAnalyzer` and `SpeechTranscriber`,
/// with translation into English by the Translation framework.
///
/// SpeechTranscriber can't detect the spoken language,
/// so a request without `language` uses the system locale.
/// The service reads any audio file that `AVAudioFile` can open,
/// which includes WAV, AIFF, CAF, M4A, AAC, MP3, FLAC, and Ogg Opus, but not WebM.
///
/// A locale's speech model must be installed.
/// The service downloads a missing model only when `allowAssetDownloads` is true;
/// otherwise a request in that locale fails with a 503 that says how to get it.
///
/// Translation uses `TranslationSession(installedSource:target:)`,
/// which works without a window but can't download languages.
/// A language pair that isn't installed fails with a 503
/// that names the System Settings pane where a person can add it.
public struct SpeechTranscriptionService: TranscriptionService, InventoryReporting {
    private let allowAssetDownloads: Bool

    public init(allowAssetDownloads: Bool = false) {
        self.allowAssetDownloads = allowAssetDownloads
    }

    public var availability: ServiceAvailability {
        SpeechTranscriber.isAvailable
            ? .available
            : .unavailable(reason: "SpeechTranscriber is not available on this Mac.")
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> Transcription {
        let locale = try await installedLocale(for: request.language)
        let file = try TemporaryAudioFile(data: request.audio, filename: request.filename)
        defer { file.remove() }

        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: file.url)
        } catch {
            throw OpenAIError.invalidRequest(
                "The server could not read the audio file. "
                    + "Supported formats: wav, aiff, caf, m4a, mp4, aac, mp3, flac, and ogg (Opus).",
                param: "file",
                code: "invalid_file_format"
            )
        }
        let sampleRate = audio.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(audio.length) / sampleRate : nil
        guard audio.length > 0 else {
            throw OpenAIError.invalidRequest("The audio file has no audio.", param: "file")
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        var segments: [Transcription.Segment] = []
        var words: [Transcription.Word] = []
        do {
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: audio,
                modules: [transcriber],
                finishAfterFile: true
            )
            for try await result in transcriber.results where result.isFinal {
                let (segment, segmentWords) = Self.segment(from: result)
                segments.append(segment)
                words += segmentWords
            }
            // The analyzer must live until its results end.
            withExtendedLifetime(analyzer) {}
        } catch let error as OpenAIError {
            throw error
        } catch {
            throw OpenAIError.server("Speech could not transcribe the audio: \(error.localizedDescription)")
        }

        return Transcription(
            text: segments.map(\.text).joined().trimmingCharacters(in: .whitespaces),
            language: locale.identifier(.bcp47),
            duration: duration,
            segments: segments,
            words: request.includeWords ? words : []
        )
    }

    public func translate(_ request: TranscriptionRequest) async throws -> Transcription {
        let transcription = try await transcribe(
            TranscriptionRequest(
                audio: request.audio,
                filename: request.filename,
                language: request.language,
                prompt: request.prompt
            )
        )
        return try await Self.translateIntoEnglish(transcription)
    }

    /// Translates a transcription's segments into English.
    static func translateIntoEnglish(_ transcription: Transcription) async throws -> Transcription {
        let source = Locale.Language(identifier: transcription.language ?? "en")
        let english = Locale.Language(identifier: "en")
        if source.languageCode == english.languageCode {
            return transcription
        }

        let sourceName = Self.languageName(source)
        guard let session = await Self.installedSession(from: source, to: english) else {
            if await LanguageAvailability().status(from: source, to: english) == .unsupported {
                throw OpenAIError.invalidRequest(
                    "The Translation framework can't translate \(sourceName) to English.",
                    param: "language",
                    code: "unsupported_language"
                )
            }
            throw OpenAIError.serviceUnavailable(
                "Translation from \(sourceName) to English is not installed on this Mac. "
                    + "Add \(sourceName) in System Settings > General > Language & Region > "
                    + "Translation Languages, then try again."
            )
        }

        let texts = transcription.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }
        let translated: [String]
        do {
            let requests = texts.enumerated().map { index, text in
                TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
            }
            let responses = try await session.translations(from: requests.filter { !$0.sourceText.isEmpty })
            var byIndex: [String: String] = [:]
            for response in responses {
                if let identifier = response.clientIdentifier {
                    byIndex[identifier] = response.targetText
                }
            }
            translated = texts.indices.map { byIndex[String($0)] ?? "" }
        } catch {
            throw OpenAIError.server("Translation failed: \(error.localizedDescription)")
        }

        let segments = zip(transcription.segments, translated).map { segment, text in
            Transcription.Segment(start: segment.start, end: segment.end, text: text, confidence: segment.confidence)
        }
        return Transcription(
            text: translated.filter { !$0.isEmpty }.joined(separator: " "),
            language: "en",
            duration: transcription.duration,
            segments: segments
        )
    }

    public func inventoryDetails() async -> [String] {
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
        let supported = await SpeechTranscriber.supportedLocales.count
        var lines = [
            "Installed speech locales: " + (installed.isEmpty ? "none" : installed.joined(separator: ", ")),
            "\(supported) locales are supported; "
                + (allowAssetDownloads
                    ? "others download when a request needs them."
                    : "start the server with --allow-asset-downloads to download others."),
        ]

        let english = Locale.Language(identifier: "en")
        var translatable: [String] = []
        for language in await LanguageAvailability().supportedLanguages
        where language.languageCode != english.languageCode {
            if await Self.installedSession(from: language, to: english) != nil {
                translatable.append(language.minimalIdentifier)
            }
        }
        lines.append(
            "Installed translations into English: "
                + (translatable.isEmpty ? "none" : Set(translatable).sorted().joined(separator: ", "))
        )
        return lines
    }

    // MARK: - Translation

    /// A session for an installed language pair, or `nil` if the pair is not installed.
    ///
    /// Since macOS 26.4, a language pair can be installed for one strategy and not the other,
    /// and the default strategy depends on the SDK that the binary links:
    /// on macOS 27, a binary built with the macOS 26 deployment target defaults to `lowLatency`,
    /// while System Settings installs `highFidelity` models.
    /// So the service tries both, high fidelity first.
    private static func installedSession(
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> TranslationSession? {
        if #available(macOS 26.4, *) {
            for strategy in [TranslationSession.Strategy.highFidelity, .lowLatency] {
                let availability = LanguageAvailability(preferredStrategy: strategy)
                if await availability.status(from: source, to: target) == .installed {
                    return TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)
                }
            }
            return nil
        }
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            return nil
        }
        return TranslationSession(installedSource: source, target: target)
    }

    // MARK: - Locales

    /// The installed locale for a request's language,
    /// downloading its assets if the service allows it.
    private func installedLocale(for language: String?) async throws -> Locale {
        let installed = await SpeechTranscriber.installedLocales
        let supported = await SpeechTranscriber.supportedLocales
        switch Self.resolveLocale(language, current: .current, installed: installed, supported: supported) {
        case .installed(let locale):
            return locale
        case .notInstalled(let locale):
            let name = Self.localeName(locale)
            guard allowAssetDownloads else {
                throw OpenAIError.serviceUnavailable(
                    "The speech model for \(name) (\(locale.identifier(.bcp47))) is not installed on this Mac. "
                        + "Restart the server with `preowned serve --allow-asset-downloads` "
                        + "to let it download the model, "
                        + "and run `preowned inventory` to list the installed locales."
                )
            }
            do {
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw OpenAIError.serviceUnavailable(
                    "Speech could not download the model for \(name): \(error.localizedDescription)"
                )
            }
            return locale
        case .unsupported:
            throw OpenAIError.invalidRequest(
                "Speech can't transcribe the language '\(language ?? Locale.current.identifier)'. "
                    + "Use an ISO-639-1 code such as 'en', or a locale such as 'en-GB'.",
                param: "language",
                code: "unsupported_language"
            )
        }
    }

    /// The result of matching a requested language to Speech's locales.
    enum LocaleResolution: Equatable {
        case installed(Locale)
        case notInstalled(Locale)
        case unsupported
    }

    /// Matches a language, such as `fr` or `en-GB`, to a locale.
    ///
    /// Without a language, the current locale applies.
    /// A language without a region prefers the current locale's region
    /// if the current locale has the same language,
    /// and then the language's most likely region, such as `fr-FR` for `fr`.
    /// An installed locale wins over one that is only supported.
    static func resolveLocale(
        _ language: String?,
        current: Locale,
        installed: [Locale],
        supported: [Locale]
    ) -> LocaleResolution {
        let requested = language.map { Locale(identifier: $0) } ?? current
        guard let code = requested.language.languageCode else {
            return .unsupported
        }
        let likelyRegion = Locale(identifier: Locale.Language(identifier: code.identifier).maximalIdentifier).region
        let preferredRegions = [
            requested.region,
            current.language.languageCode == code ? current.region : nil,
            likelyRegion,
        ]
        .compactMap { $0 }

        func best(in locales: [Locale]) -> Locale? {
            let matches = locales.filter { $0.language.languageCode == code }
            for region in preferredRegions {
                if let match = matches.first(where: { $0.region == region }) {
                    return match
                }
            }
            return matches.min { $0.identifier < $1.identifier }
        }

        if let locale = best(in: installed) {
            // A requested region that is supported but not installed
            // is better than another installed region only if the client named it.
            if let region = requested.region, locale.region != region, language != nil,
                let exact = supported.first(where: { $0.language.languageCode == code && $0.region == region })
            {
                return .notInstalled(exact)
            }
            return .installed(locale)
        }
        if let locale = best(in: supported) {
            return .notInstalled(locale)
        }
        return .unsupported
    }

    private static func localeName(_ locale: Locale) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func languageName(_ language: Locale.Language) -> String {
        language.languageCode.flatMap {
            Locale(identifier: "en").localizedString(forLanguageCode: $0.identifier)
        } ?? language.minimalIdentifier
    }

    // MARK: - Results

    /// A segment and its words from a final result.
    private static func segment(
        from result: SpeechTranscriber.Result
    ) -> (Transcription.Segment, [Transcription.Word]) {
        var words: [Transcription.Word] = []
        var confidences: [Double] = []
        for run in result.text.runs {
            if let confidence = run.transcriptionConfidence {
                confidences.append(confidence)
            }
            guard let range = run.audioTimeRange else { continue }
            let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            words.append(Transcription.Word(word: word, start: range.start.seconds, end: range.end.seconds))
        }
        let segment = Transcription.Segment(
            start: result.range.start.seconds,
            end: result.range.end.seconds,
            text: String(result.text.characters),
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        )
        return (segment, words)
    }
}

/// Audio data in a temporary file, which `AVAudioFile` needs.
private struct TemporaryAudioFile {
    let url: URL

    init(data: Data, filename: String?) throws {
        // The extension helps Core Audio pick a parser,
        // but it also sniffs the content.
        let pathExtension = filename.map { ($0 as NSString).pathExtension }.flatMap { name in
            name.isEmpty || name.count > 8 || !name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
                ? nil : name
        }
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preowned-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension?.lowercased() ?? "audio")
        do {
            try data.write(to: url)
        } catch {
            throw OpenAIError.server("The server could not save the audio file: \(error.localizedDescription)")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
