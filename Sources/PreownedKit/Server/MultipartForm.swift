import Foundation
import Hummingbird

/// A parsed `multipart/form-data` body (RFC 7578).
///
/// The parser follows RFC 2046 strictly for delimiters:
/// each boundary line starts with CRLF and `--`,
/// and the CRLF before a boundary belongs to the boundary, not to the part.
/// A part's data is kept byte for byte,
/// so binary files with CR, LF, or `--` inside them survive intact.
///
/// A malformed body throws an OpenAI `invalid_request_error` with status 400.
public struct MultipartForm: Sendable {
    /// A part of the form, usually an uploaded file.
    public struct File: Sendable {
        /// The `filename` parameter of the part's `Content-Disposition` header.
        public var filename: String?
        /// The part's `Content-Type` header.
        public var contentType: String?
        /// The part's data.
        public var data: Data
    }

    /// One part of the body, in the order that the body sends it.
    private struct Part: Sendable {
        var name: String
        var file: File
    }

    private var parts: [Part]

    /// Parses a body with the boundary from a `Content-Type` header value,
    /// such as `multipart/form-data; boundary=X`.
    public init(contentType: String, body: Data) throws {
        let boundary = Array(try Self.boundary(from: contentType).utf8)
        self.parts = try body.withUnsafeBytes { try Self.parse($0, boundary: boundary) }
    }

    /// Parses a body in place in a buffer.
    ///
    /// The parser reads the buffer's bytes without copying them,
    /// and copies each part's data once.
    public init(contentType: String, buffer: ByteBuffer) throws {
        let boundary = Array(try Self.boundary(from: contentType).utf8)
        self.parts = try buffer.withUnsafeReadableBytes { try Self.parse($0, boundary: boundary) }
    }

    /// The value of the first text field with a name,
    /// or `nil` if the form has no such field or its value is not UTF-8.
    ///
    /// A part with a `filename` is a file, not a text field.
    public func field(_ name: String) -> String? {
        guard let part = parts.first(where: { $0.name == name && $0.file.filename == nil }) else {
            return nil
        }
        return String(data: part.file.data, encoding: .utf8)
    }

    /// The first part with a name, with or without a `filename`.
    public func file(_ name: String) -> File? {
        parts.first { $0.name == name }?.file
    }

    /// Every part with a name, in order, with or without a `filename`.
    ///
    /// The name must match exactly,
    /// so a client that sends `image[]` needs `files("image[]")`.
    public func files(_ name: String) -> [File] {
        parts.filter { $0.name == name }.map(\.file)
    }
}

// MARK: - Content-Type

extension MultipartForm {
    private static func boundary(from contentType: String) throws -> String {
        let (value, parameters) = HeaderValue.parse(contentType)
        guard value.lowercased() == "multipart/form-data" else {
            throw malformed("The Content-Type must be multipart/form-data.")
        }
        guard let boundary = parameters["boundary"], !boundary.isEmpty else {
            throw malformed("The multipart/form-data Content-Type has no boundary.")
        }
        // RFC 2046 limits a boundary to 70 characters.
        guard boundary.utf8.count <= 70, boundary.allSatisfy({ $0.isASCII && $0 != "\r" && $0 != "\n" }) else {
            throw malformed("The multipart boundary is not valid.")
        }
        return boundary
    }

    private static func malformed(_ message: String) -> OpenAIError {
        OpenAIError.invalidRequest(message)
    }
}

// MARK: - Body

extension MultipartForm {
    private static let crlf: [UInt8] = [13, 10]
    private static let headerEnd: [UInt8] = [13, 10, 13, 10]

    private static func parse(_ bytes: UnsafeRawBufferPointer, boundary: [UInt8]) throws -> [Part] {
        let dashBoundary = [45, 45] + boundary
        let delimiter = crlf + dashBoundary

        // The first boundary can start the body or follow a preamble,
        // in which case it follows a CRLF like every other boundary.
        var position: Int
        if bytes.starts(with: dashBoundary) {
            position = dashBoundary.count
        } else if let found = search(delimiter, in: bytes, from: 0) {
            position = found + delimiter.count
        } else {
            throw malformed("The multipart body has no boundary.")
        }

        var parts: [Part] = []
        while true {
            // After a boundary comes `--` for the end of the body,
            // or optional whitespace and a CRLF before the next part.
            if bytes[position...].starts(with: [45, 45]) {
                return parts
            }
            while position < bytes.count, bytes[position] == 32 || bytes[position] == 9 {
                position += 1
            }
            guard bytes[position...].starts(with: crlf) else {
                throw malformed("The multipart body has a malformed boundary line.")
            }
            position += crlf.count

            let headers: [String: String]
            if bytes[position...].starts(with: crlf) {
                // A part with no headers.
                headers = [:]
                position += crlf.count
            } else {
                guard let end = search(headerEnd, in: bytes, from: position) else {
                    throw malformed("A part of the multipart body has unterminated headers.")
                }
                headers = try parseHeaders(bytes[position..<end])
                position = end + headerEnd.count
            }

            guard let end = search(delimiter, in: bytes, from: position) else {
                throw malformed("The multipart body ends without a closing boundary.")
            }
            let data = Data(UnsafeRawBufferPointer(rebasing: bytes[position..<end]))
            position = end + delimiter.count

            parts.append(try part(headers: headers, data: data))
        }
    }

    private static func parseHeaders(_ bytes: Slice<UnsafeRawBufferPointer>) throws -> [String: String] {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw malformed("A part of the multipart body has headers that are not UTF-8.")
        }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                throw malformed("A part of the multipart body has a malformed header.")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    private static func part(headers: [String: String], data: Data) throws -> Part {
        guard let disposition = headers["content-disposition"] else {
            throw malformed("A part of the multipart body has no Content-Disposition header.")
        }
        let (type, parameters) = HeaderValue.parse(disposition)
        guard type.lowercased() == "form-data", let name = parameters["name"] else {
            throw malformed("A part of the multipart body has no form-data name.")
        }
        let filename = parameters["filename*"].flatMap(HeaderValue.decodeExtendedValue) ?? parameters["filename"]
        return Part(
            name: name,
            file: File(filename: filename, contentType: headers["content-type"], data: data)
        )
    }

    /// The offset of the first occurrence of `needle` in `haystack` at or after `start`.
    private static func search(_ needle: [UInt8], in haystack: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard start <= haystack.count, !needle.isEmpty, let base = haystack.baseAddress else { return nil }
        return needle.withUnsafeBytes { pattern in
            guard let patternBase = pattern.baseAddress,
                let match = memmem(base + start, haystack.count - start, patternBase, pattern.count)
            else {
                return nil
            }
            return base.distance(to: UnsafeRawPointer(match))
        }
    }
}

// MARK: - Header values

/// A header value with parameters, such as
/// `form-data; name="file"; filename="a.wav"`.
private enum HeaderValue {
    /// Splits a value into its first token and its parameters.
    ///
    /// Parameter names are lowercased.
    /// Quoted values can contain `;` and backslash escapes.
    static func parse(_ header: String) -> (value: String, parameters: [String: String]) {
        var segments: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        for character in header {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if isQuoted && character == "\\" {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                current.append(character)
                isQuoted.toggle()
            } else if character == ";" && !isQuoted {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)

        let value = segments.removeFirst().trimmingCharacters(in: .whitespaces)
        var parameters: [String: String] = [:]
        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let name = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // The first occurrence of a parameter wins.
            if parameters[name] == nil {
                parameters[name] = unquote(raw)
            }
        }
        return (value, parameters)
    }

    /// Removes the quotes and backslash escapes from a quoted string.
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else {
            return raw
        }
        var result = ""
        var isEscaped = false
        for character in raw.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Decodes an RFC 8187 extended value, such as `UTF-8''na%C3%AFve.wav`.
    ///
    /// Only UTF-8 values decode;
    /// for other charsets, the plain `filename` parameter applies.
    static func decodeExtendedValue(_ value: String) -> String? {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].lowercased() == "utf-8" else {
            return nil
        }
        return String(pieces[2]).removingPercentEncoding
    }
}
