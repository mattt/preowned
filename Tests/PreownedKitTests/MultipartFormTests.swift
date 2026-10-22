import Foundation
import Testing

@testable import PreownedKit

@Suite("Multipart form parsing")
struct MultipartFormTests {
    let contentType = "multipart/form-data; boundary=XyZ"

    /// Joins lines with CRLF.
    func body(_ lines: String...) -> Data {
        Data(lines.joined(separator: "\r\n").utf8)
    }

    @Test("Text fields and a file")
    func fieldsAndFile() throws {
        let form = try MultipartForm(
            contentType: contentType,
            body: body(
                "--XyZ",
                #"Content-Disposition: form-data; name="model""#,
                "",
                "whisper-1",
                "--XyZ",
                #"Content-Disposition: form-data; name="file"; filename="speech.wav""#,
                "Content-Type: audio/wav",
                "",
                "RIFF....",
                "--XyZ--",
                ""
            )
        )
        #expect(form.field("model") == "whisper-1")
        let file = try #require(form.file("file"))
        #expect(file.filename == "speech.wav")
        #expect(file.contentType == "audio/wav")
        #expect(file.data == Data("RIFF....".utf8))
        #expect(form.field("file") == nil)
        #expect(form.field("missing") == nil)
        #expect(form.file("missing") == nil)
    }

    @Test("An empty field value and a multiline value")
    func emptyAndMultilineValues() throws {
        let form = try MultipartForm(
            contentType: contentType,
            body: body(
                "--XyZ",
                #"Content-Disposition: form-data; name="empty""#,
                "",
                "",
                "--XyZ",
                #"Content-Disposition: form-data; name="prompt""#,
                "",
                "line one",
                "line two",
                "",
                "--XyZ--"
            )
        )
        #expect(form.field("empty") == "")
        #expect(form.field("prompt") == "line one\r\nline two\r\n")
    }

    @Test("Binary data with CR, LF, NUL, and dashes survives byte for byte")
    func binaryData() throws {
        var payload = Data((0...255).map { UInt8($0) })
        payload.append(contentsOf: Array("\r\n--XyY\r\n--\r\n\n\r".utf8))
        payload.append(contentsOf: [0, 13, 10, 13, 10, 45, 45])

        var data = Data("--XyZ\r\n".utf8)
        data.append(Data(#"Content-Disposition: form-data; name="file"; filename="blob.bin""#.utf8))
        data.append(Data("\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        data.append(payload)
        data.append(Data("\r\n--XyZ--\r\n".utf8))

        let form = try MultipartForm(contentType: contentType, body: data)
        #expect(form.file("file")?.data == payload)
    }

    @Test("Several files with the same name keep their order")
    func repeatedNames() throws {
        let form = try MultipartForm(
            contentType: contentType,
            body: body(
                "--XyZ",
                #"Content-Disposition: form-data; name="image[]"; filename="a.png""#,
                "",
                "first",
                "--XyZ",
                #"Content-Disposition: form-data; name="image[]"; filename="b.png""#,
                "",
                "second",
                "--XyZ",
                #"Content-Disposition: form-data; name="timestamp_granularities[]""#,
                "",
                "word",
                "--XyZ",
                #"Content-Disposition: form-data; name="timestamp_granularities[]""#,
                "",
                "segment",
                "--XyZ--"
            )
        )
        let images = form.files("image[]")
        #expect(images.map(\.filename) == ["a.png", "b.png"])
        #expect(images.map { String(decoding: $0.data, as: UTF8.self) } == ["first", "second"])
        #expect(form.file("image[]")?.filename == "a.png")
        #expect(form.files("image").isEmpty)
        let granularities = form.files("timestamp_granularities[]").map {
            String(decoding: $0.data, as: UTF8.self)
        }
        #expect(granularities == ["word", "segment"])
        #expect(form.field("timestamp_granularities[]") == "word")
    }

    @Test(
        "Content-Type parameters can be quoted, reordered, and in any case",
        arguments: [
            #"multipart/form-data; boundary="XyZ""#,
            "multipart/form-data;boundary=XyZ",
            "Multipart/Form-Data; charset=utf-8; BOUNDARY=XyZ",
            #"multipart/form-data; boundary="XyZ"; charset="utf-8""#,
        ]
    )
    func contentTypeVariants(contentType: String) throws {
        let form = try MultipartForm(
            contentType: contentType,
            body: body("--XyZ", #"Content-Disposition: form-data; name="a""#, "", "1", "--XyZ--")
        )
        #expect(form.field("a") == "1")
    }

    @Test("A quoted boundary can contain spaces and other special characters")
    func quotedBoundary() throws {
        let form = try MultipartForm(
            contentType: #"multipart/form-data; boundary="a b:c=d,e""#,
            body: body("--a b:c=d,e", #"Content-Disposition: form-data; name="a""#, "", "1", "--a b:c=d,e--")
        )
        #expect(form.field("a") == "1")
    }

    @Test("Disposition parameters handle quotes, escapes, semicolons, and RFC 8187 names")
    func dispositionParameters() throws {
        let form = try MultipartForm(
            contentType: contentType,
            body: body(
                "--XyZ",
                #"content-disposition: form-data; filename="we \"said\"; ok.wav"; name="file""#,
                "CONTENT-TYPE: audio/wav",
                "",
                "x",
                "--XyZ",
                #"Content-Disposition: form-data; name=other; filename*=UTF-8''na%C3%AFve%20file.mp3; filename="naive.mp3""#,
                "",
                "y",
                "--XyZ",
                #"Content-Disposition: form-data; name="plain""#,
                "",
                "z",
                "--XyZ--"
            )
        )
        let file = try #require(form.file("file"))
        #expect(file.filename == #"we "said"; ok.wav"#)
        #expect(file.contentType == "audio/wav")
        #expect(form.file("other")?.filename == "naïve file.mp3")
        #expect(form.file("plain")?.filename == nil)
        #expect(form.file("plain")?.contentType == nil)
    }

    @Test("A preamble, an epilogue, and whitespace after a boundary are allowed")
    func preambleAndEpilogue() throws {
        let form = try MultipartForm(
            contentType: contentType,
            body: body(
                "This is the preamble.",
                "--XyZ  \t",
                #"Content-Disposition: form-data; name="a""#,
                "",
                "1",
                "--XyZ--",
                "This is the epilogue with --XyZ inside."
            )
        )
        #expect(form.field("a") == "1")
    }

    @Test("A body without parts parses as an empty form")
    func emptyForm() throws {
        let form = try MultipartForm(contentType: contentType, body: Data("--XyZ--\r\n".utf8))
        #expect(form.files("a").isEmpty)
    }

    @Test("A field that is not UTF-8 reads as nil, but its file data stays")
    func nonUTF8Field() throws {
        var data = Data("--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(Data("\r\n--XyZ--".utf8))
        let form = try MultipartForm(contentType: contentType, body: data)
        #expect(form.field("a") == nil)
        #expect(form.file("a")?.data == Data([0xFF, 0xFE]))
    }

    @Test(
        "A Content-Type that is not multipart or has no boundary is rejected",
        arguments: [
            "application/json",
            "multipart/mixed; boundary=XyZ",
            "multipart/form-data",
            "multipart/form-data; boundary=",
            #"multipart/form-data; boundary="""#,
            "multipart/form-data; boundary=" + String(repeating: "a", count: 71),
        ]
    )
    func rejectsContentType(contentType: String) throws {
        let error = #expect(throws: OpenAIError.self) {
            try MultipartForm(
                contentType: contentType,
                body: body("--XyZ", #"Content-Disposition: form-data; name="a""#, "", "1", "--XyZ--")
            )
        }
        #expect(error?.status == .badRequest)
        #expect(error?.type == "invalid_request_error")
    }

    @Test(
        "A malformed body is rejected with a 400",
        arguments: [
            // No boundary at all.
            "just some text",
            // No closing boundary.
            "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1",
            // Headers that never end.
            "--XyZ\r\nContent-Disposition: form-data; name=\"a\"\r\n",
            // Bare LF line endings.
            "--XyZ\nContent-Disposition: form-data; name=\"a\"\n\n1\n--XyZ--",
            // No Content-Disposition.
            "--XyZ\r\nContent-Type: text/plain\r\n\r\n1\r\n--XyZ--",
            // No name.
            "--XyZ\r\nContent-Disposition: form-data; filename=\"a.wav\"\r\n\r\n1\r\n--XyZ--",
            // Not form-data.
            "--XyZ\r\nContent-Disposition: attachment; name=\"a\"\r\n\r\n1\r\n--XyZ--",
            // A header line without a colon.
            "--XyZ\r\nContent-Disposition form-data\r\n\r\n1\r\n--XyZ--",
            // Text after the boundary on the same line.
            "--XyZjunk\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--XyZ--",
            // An empty body.
            "",
        ]
    )
    func rejectsMalformedBody(text: String) throws {
        let error = #expect(throws: OpenAIError.self) {
            try MultipartForm(contentType: contentType, body: Data(text.utf8))
        }
        #expect(error?.status == .badRequest)
        #expect(error?.type == "invalid_request_error")
    }

    @Test("A part without headers has no name and is rejected")
    func partWithoutHeaders() throws {
        #expect(throws: OpenAIError.self) {
            try MultipartForm(contentType: contentType, body: body("--XyZ", "", "1", "--XyZ--"))
        }
    }

    @Test("A large binary file parses")
    func largeFile() throws {
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var data = Data()
        data.append(Data("--XyZ\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n".utf8))
        data.append(Data("--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.raw\"\r\n\r\n".utf8))
        data.append(payload)
        data.append(Data("\r\n--XyZ--\r\n".utf8))
        let form = try MultipartForm(contentType: contentType, body: data)
        #expect(form.file("file")?.data == payload)
        #expect(form.field("model") == "whisper-1")
    }
}
