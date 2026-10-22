/// Maps OpenAI voice names to the system voices on this Mac.
///
/// Each OpenAI voice has a list of Apple voices,
/// chosen by gender and character, in order of preference:
///
/// | OpenAI | Apple voices | Gender |
/// | --- | --- | --- |
/// | alloy | Samantha, Ava, Allison | female |
/// | ash | Evan, Nathan, Reed | male |
/// | ballad | Oliver, Arthur, Grandpa | male |
/// | coral | Ava, Zoe, Shelley | female |
/// | echo | Tom, Aaron, Eddy | male |
/// | fable | Daniel, Arthur, Oliver | male |
/// | onyx | Nathan, Evan, Rocko | male |
/// | nova | Allison, Nicky, Sandy | female |
/// | sage | Susan, Kate, Flo | female |
/// | shimmer | Zoe, Joelle, Moira | female |
/// | verse | Evan, Aaron, Fred | male |
///
/// The catalog picks the first listed name that is installed in English,
/// in its best installed quality, preferring `en-US`.
/// If none is installed, it picks the best English voice of the same gender,
/// and then the system's default English voice.
/// Novelty voices, such as Bells, and Personal Voices are never picked.
///
/// If the input's dominant language is not English,
/// the catalog picks a voice for that language instead:
/// the same name if it exists in that language, as the Eloquence voices do,
/// then the best voice of the same gender, then any voice for the language.
///
/// A request can also name a system voice by its identifier or name,
/// such as `com.apple.voice.compact.en-US.Samantha` or `Samantha`.
public enum VoiceCatalog {
    /// The OpenAI voice names, in OpenAI's order.
    public static let openAIVoices = [
        "alloy", "ash", "ballad", "coral", "echo", "fable", "onyx", "nova", "sage", "shimmer", "verse",
    ]

    /// The Apple voice names and gender for each OpenAI voice.
    static let table: [String: (names: [String], gender: Voice.Gender)] = [
        "alloy": (["Samantha", "Ava", "Allison"], .female),
        "ash": (["Evan", "Nathan", "Reed"], .male),
        "ballad": (["Oliver", "Arthur", "Grandpa"], .male),
        "coral": (["Ava", "Zoe", "Shelley"], .female),
        "echo": (["Tom", "Aaron", "Eddy"], .male),
        "fable": (["Daniel", "Arthur", "Oliver"], .male),
        "onyx": (["Nathan", "Evan", "Rocko"], .male),
        "nova": (["Allison", "Nicky", "Sandy"], .female),
        "sage": (["Susan", "Kate", "Flo"], .female),
        "shimmer": (["Zoe", "Joelle", "Moira"], .female),
        "verse": (["Evan", "Aaron", "Fred"], .male),
    ]

    /// A system voice, independent of AVFoundation so that tests can build a list.
    public struct Voice: Sendable, Equatable {
        public enum Gender: Sendable, Equatable {
            case male
            case female
            case unspecified
        }

        public var identifier: String
        public var name: String
        /// A BCP 47 language, such as `en-US`.
        public var language: String
        /// The voice's quality: 1 for default, 2 for enhanced, 3 for premium.
        public var quality: Int
        public var gender: Gender
        /// Whether the voice is a novelty or Personal Voice, which the catalog never picks.
        public var isExcluded: Bool

        public init(
            identifier: String,
            name: String,
            language: String,
            quality: Int = 1,
            gender: Gender = .unspecified,
            isExcluded: Bool = false
        ) {
            self.identifier = identifier
            self.name = name
            self.language = language
            self.quality = quality
            self.gender = gender
            self.isExcluded = isExcluded
        }

        var languageCode: String {
            String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
        }
    }

    /// The voice for a request, or `nil` if the name is neither an OpenAI voice nor a system voice.
    ///
    /// - Parameters:
    ///   - name: An OpenAI voice name or a system voice's identifier or name.
    ///   - language: The input's dominant language code, such as `fr`, if known.
    ///   - voices: The installed voices.
    ///   - defaultEnglishIdentifier: The identifier of the system's default English voice.
    public static func voice(
        named name: String,
        language: String?,
        in voices: [Voice],
        defaultEnglishIdentifier: String?
    ) -> Voice? {
        let key = name.lowercased()
        guard let entry = table[key] else {
            return voices.first { $0.identifier == name }
                ?? voices.first { !$0.isExcluded && $0.name.lowercased() == key && $0.languageCode == "en" }
                ?? voices.first { !$0.isExcluded && $0.name.lowercased() == key }
        }
        let candidates = voices.filter { !$0.isExcluded }

        if let language = language?.lowercased(), language != "en" {
            let local = candidates.filter { $0.languageCode == language }
            if !local.isEmpty {
                for name in entry.names {
                    if let match = best(local.filter { $0.name == name }, region: nil) {
                        return match
                    }
                }
                return best(local.filter { $0.gender == entry.gender }, region: nil) ?? best(local, region: nil)
            }
        }

        let english = candidates.filter { $0.languageCode == "en" }
        for name in entry.names {
            if let match = best(english.filter { $0.name == name }, region: "US") {
                return match
            }
        }
        return best(english.filter { $0.gender == entry.gender }, region: "US")
            ?? voices.first { $0.identifier == defaultEnglishIdentifier }
            ?? best(english, region: "US")
            ?? candidates.first
    }

    /// The voice with the highest quality, preferring a region on a tie.
    private static func best(_ voices: [Voice], region: String?) -> Voice? {
        voices.max { lhs, rhs in
            if lhs.quality != rhs.quality {
                return lhs.quality < rhs.quality
            }
            let lhsRegion = region.map { lhs.language.hasSuffix($0) } ?? false
            let rhsRegion = region.map { rhs.language.hasSuffix($0) } ?? false
            if lhsRegion != rhsRegion {
                return !lhsRegion
            }
            // A stable choice: the smaller identifier wins.
            return lhs.identifier > rhs.identifier
        }
    }

    /// The `AVSpeechUtterance` rate for an OpenAI speed multiplier.
    ///
    /// The rate is not linear in speed.
    /// The table holds the speed of the Samantha voice at each rate,
    /// measured on macOS 27.0.1 against its length at the default rate of 0.5.
    /// Other voices scale differently, so the speed is approximate.
    /// The slowest rate is about 0.56× and the fastest about 4×,
    /// so slower speeds use the slowest rate.
    public static func rate(forSpeed speed: Double) -> Float {
        let table: [(speed: Double, rate: Double)] = [
            (0.56, 0.0), (0.67, 0.1), (0.71, 0.2), (0.83, 0.3), (0.91, 0.4), (1.0, 0.5),
            (1.59, 0.6), (2.11, 0.7), (2.82, 0.8), (3.51, 0.9), (4.03, 1.0),
        ]
        guard let first = table.first, let last = table.last else { return 0.5 }
        if speed <= first.speed { return Float(first.rate) }
        if speed >= last.speed { return Float(last.rate) }
        for (lower, upper) in zip(table, table.dropFirst()) where speed <= upper.speed {
            let fraction = (speed - lower.speed) / (upper.speed - lower.speed)
            return Float(lower.rate + fraction * (upper.rate - lower.rate))
        }
        return Float(last.rate)
    }
}
