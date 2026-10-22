import Foundation

/// A parsed `multipart/form-data` body.
///
/// The parser reads the whole body into memory,
/// which fits the size limit of ``PreownedServer/maximumBodySize``.
/// A part with a `filename` parameter is a file;
/// any other part is a text field.
public struct MultipartForm: Sendable {
    /// An uploaded file.
    public struct File: Sendable {
        public var filename: String?
        public var contentType: String?
        public var data: Data

        public init(filename: String?, contentType: String?, data: Data) {
            self.filename = filename
            self.contentType = contentType
            self.data = data
        }
    }

    private struct Part {
        var name: String
        var filename: String?
        var contentType: String?
        var data: Data
        var isFile: Bool
    }

    private var parts: [Part]

    /// Parses a body with the boundary from its `Content-Type` header.
    ///
    /// - Throws: An ``OpenAIError`` with status 400
    ///   when the content type is not `multipart/form-data`,
    ///   has no boundary,
    ///   or the body does not match it.
    public init(contentType: String, body: Data) throws {
        guard let boundary = Self.boundary(in: contentType) else {
            throw OpenAIError.invalidRequest(
                "The request must have the content type `multipart/form-data` with a boundary."
            )
        }
        parts = try Self.parse(body: body, boundary: boundary)
    }

    /// The value of the first text field with a name.
    public func field(_ name: String) -> String? {
        parts.first { $0.name == name && !$0.isFile }
            .map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// The first file with a name.
    public func file(_ name: String) -> File? {
        files(name).first
    }

    /// Every file with a name, in order,
    /// such as the parts of OpenAI's `image[]` array.
    public func files(_ name: String) -> [File] {
        parts.filter { $0.name == name && $0.isFile }
            .map { File(filename: $0.filename, contentType: $0.contentType, data: $0.data) }
    }

    // MARK: - Parsing

    private static func malformed(_ detail: String) -> OpenAIError {
        .invalidRequest("The multipart body is malformed: \(detail).")
    }

    /// The `boundary` parameter of a `multipart/form-data` content type.
    static func boundary(in contentType: String) -> String? {
        let pieces = contentType.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let type = pieces.first, type.lowercased() == "multipart/form-data" else {
            return nil
        }
        for piece in pieces.dropFirst() {
            guard let (key, value) = parameter(piece), key == "boundary", !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private static func parse(body: Data, boundary: String) throws -> [Part] {
        let bytes = [UInt8](body)
        let delimiter = Array("--\(boundary)".utf8)
        let crlf: [UInt8] = [13, 10]

        // The body starts with the first delimiter;
        // anything before it is a preamble that the parser skips.
        guard var position = find(delimiter, in: bytes, from: 0) else {
            throw malformed("the boundary does not appear in the body")
        }
        position += delimiter.count

        var parts: [Part] = []
        while true {
            // `--` after a delimiter closes the body.
            if bytes[position...].starts(with: [45, 45]) {
                return parts
            }
            guard bytes[position...].starts(with: crlf) else {
                throw malformed("a boundary is not followed by a line break")
            }
            position += crlf.count

            guard let next = find(crlf + delimiter, in: bytes, from: position) else {
                throw malformed("a part has no closing boundary")
            }
            parts.append(try part(bytes[position..<next]))
            position = next + crlf.count + delimiter.count
        }
    }

    private static func part(_ bytes: ArraySlice<UInt8>) throws -> Part {
        let separator: [UInt8] = [13, 10, 13, 10]
        let headerBytes: ArraySlice<UInt8>
        let content: ArraySlice<UInt8>
        if bytes.starts(with: [13, 10]) {
            // A part with no headers.
            headerBytes = []
            content = bytes.dropFirst(2)
        } else if let end = find(separator, in: Array(bytes), from: 0) {
            headerBytes = bytes.prefix(end)
            content = bytes.dropFirst(end + separator.count)
        } else {
            throw malformed("a part has no blank line after its headers")
        }

        var name: String?
        var filename: String?
        var contentType: String?
        let headers = String(decoding: headerBytes, as: UTF8.self)
        for line in headers.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw malformed("a part header has no colon")
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "content-disposition":
                let pieces = splitParameters(value)
                guard pieces.first?.lowercased() == "form-data" else {
                    throw malformed("a part is not `form-data`")
                }
                for piece in pieces.dropFirst() {
                    guard let (key, value) = parameter(piece) else { continue }
                    switch key {
                    case "name": name = value
                    case "filename": filename = value
                    default: break
                    }
                }
            case "content-type":
                contentType = value
            default:
                break
            }
        }

        guard let name else {
            throw malformed("a part has no name")
        }
        return Part(
            name: name,
            filename: filename,
            contentType: contentType,
            data: Data(content),
            isFile: filename != nil
        )
    }

    /// Splits a header value at semicolons outside quoted strings.
    private static func splitParameters(_ value: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        for character in value {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" && isQuoted {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
            } else if character == ";" && !isQuoted {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current.trimmingCharacters(in: .whitespaces))
        return pieces
    }

    /// A `key=value` parameter with a lowercase key
    /// and the value without quotes or escapes.
    private static func parameter(_ piece: String) -> (String, String)? {
        guard let equals = piece.firstIndex(of: "=") else { return nil }
        let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
            var unescaped = ""
            var isEscaped = false
            for character in value {
                if character == "\\" && !isEscaped {
                    isEscaped = true
                    continue
                }
                isEscaped = false
                unescaped.append(character)
            }
            value = unescaped
        }
        return (key, value)
    }

    /// The index of the first occurrence of `needle` in `haystack` at or after `start`.
    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}
