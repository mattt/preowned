/// How a service turns a prompt into an Image Playground concept.
///
/// A short prompt becomes `.text(_:)`.
/// A prompt longer than ``extractionThreshold`` characters
/// becomes `.extracted(from:title:)`,
/// which asks Image Playground to pick the key ideas out of a longer text.
public enum ImagePromptConcept: Sendable, Equatable {
    case text
    case extracted

    /// The longest prompt, in characters, that becomes `.text(_:)`.
    public static let extractionThreshold = 200

    /// The concept kind for a prompt.
    public init(prompt: String) {
        self = prompt.count > Self.extractionThreshold ? .extracted : .text
    }
}

/// Maps the `style` of a request to an Image Playground style name.
///
/// A request can name any style that the service lists,
/// such as `animation`, `illustration`, or `sketch`.
/// OpenAI's DALL-E 3 styles map to the nearest Image Playground style:
///
/// - `vivid` (hyper-real, dramatic images) maps to `animation`,
///   the bolder, more saturated style.
/// - `natural` (more natural, less dramatic images) maps to `illustration`.
public enum ImageStyleMapping {
    /// OpenAI style names and the Image Playground styles that they map to.
    public static let openAIAliases: [String: String] = [
        "vivid": "animation",
        "natural": "illustration",
    ]

    /// Returns the Image Playground style for a requested style,
    /// or `nil` for the service's default.
    public static func resolve(
        _ requested: String?,
        available: [String]
    ) throws(OpenAIError) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let name = requested.lowercased()
        let style = openAIAliases[name] ?? name
        if available.contains(style) {
            return style
        }
        let accepted = available + openAIAliases.keys.sorted().filter { available.contains(openAIAliases[$0]!) }
        throw .invalidRequest(
            "Invalid value for 'style': '\(requested)'. "
                + "Supported values are: \(accepted.map { "'\($0)'" }.joined(separator: ", ")).",
            param: "style",
            code: "invalid_value"
        )
    }
}

/// The `response_format` of an image request.
public enum ImageResponseFormat: String, Sendable, Equatable {
    /// Base64-encoded PNG data in `b64_json`.
    case b64JSON = "b64_json"
    /// A `data:image/png;base64,` URL in `url`,
    /// because preowned has no place to host files.
    case url

    /// Parses a `response_format` value, which defaults to `b64_json`.
    public init(parsing value: String?) throws(OpenAIError) {
        guard let value, !value.isEmpty else {
            self = .b64JSON
            return
        }
        guard let format = Self(rawValue: value) else {
            throw .invalidRequest(
                "Invalid value for 'response_format': '\(value)'. Supported values are: 'b64_json' and 'url'.",
                param: "response_format",
                code: "invalid_value"
            )
        }
        self = format
    }
}

extension ImageSize {
    /// Parses a `size` value such as `1024x1024`.
    ///
    /// `auto` and a missing value give `nil`.
    public init?(parsing value: String?) throws(OpenAIError) {
        guard let value, !value.isEmpty, value != "auto" else { return nil }
        let pieces = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard pieces.count == 2,
            let width = Int(pieces[0]), let height = Int(pieces[1]),
            (1...8192).contains(width), (1...8192).contains(height)
        else {
            throw .invalidRequest(
                "Invalid value for 'size': '\(value)'. Use 'auto' or WIDTHxHEIGHT, such as '1024x1024'.",
                param: "size",
                code: "invalid_value"
            )
        }
        self.init(width: width, height: height)
    }
}

/// The number of images in a request.
public enum ImageCount {
    /// The largest `n` that OpenAI accepts.
    public static let maximum = 10

    /// Validates `n`, which defaults to 1.
    public static func validate(_ n: Int?) throws(OpenAIError) -> Int {
        let count = n ?? 1
        guard (1...maximum).contains(count) else {
            throw .invalidRequest(
                "Invalid value for 'n': \(count). It must be between 1 and \(maximum).",
                param: "n",
                code: "invalid_value"
            )
        }
        return count
    }
}
