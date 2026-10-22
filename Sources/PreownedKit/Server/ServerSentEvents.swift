import Foundation
import Hummingbird

/// Frames for OpenAI's server-sent event streams.
///
/// Each event is one `data:` line followed by a blank line.
/// The stream ends with `data: [DONE]`.
enum ServerSentEvents {
    static let headers: HTTPFields = [
        .contentType: "text/event-stream",
        .cacheControl: "no-cache",
    ]

    /// An event that carries a JSON value.
    static func event(_ value: some Encodable) throws -> ByteBuffer {
        var buffer = ByteBuffer(string: "data: ")
        buffer.writeBytes(try JSONCoding.encoder.encode(value))
        buffer.writeString("\n\n")
        return buffer
    }

    /// The event that ends a stream.
    static let done = ByteBuffer(string: "data: [DONE]\n\n")
}
