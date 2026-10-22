import Foundation
import Testing

@testable import PreownedKit

@Suite("Multipart form parsing")
struct MultipartFormTests {
    @Test("Fields and files parse with their names, file names, and content types")
    func parsesFieldsAndFiles() throws {
        let body = FormDataBuilder()
            .field("prompt", "a red bicycle")
            .file("image", filename: "bike.png", contentType: "image/png", data: Data([0, 1, 2, 13, 10, 255]))
            .field("n", "2")
        let form = try MultipartForm(contentType: body.contentType, body: body.body)

        #expect(form.field("prompt") == "a red bicycle")
        #expect(form.field("n") == "2")
        #expect(form.field("missing") == nil)
        let file = try #require(form.file("image"))
        #expect(file.filename == "bike.png")
        #expect(file.contentType == "image/png")
        #expect(file.data == Data([0, 1, 2, 13, 10, 255]))
        // A file is not a field, and a field is not a file.
        #expect(form.field("image") == nil)
        #expect(form.file("prompt") == nil)
    }

    @Test("Repeated names return every file in order")
    func repeatedFiles() throws {
        let body = FormDataBuilder()
            .file("image[]", filename: "a.png", data: Data("a".utf8))
            .file("image[]", filename: "b.png", data: Data("b".utf8))
        let form = try MultipartForm(contentType: body.contentType, body: body.body)
        #expect(form.files("image[]").map(\.filename) == ["a.png", "b.png"])
        #expect(form.files("image[]").map(\.data) == [Data("a".utf8), Data("b".utf8)])
        #expect(form.files("image").isEmpty)
    }

    @Test("A quoted boundary, a preamble, an empty file, and a UTF-8 field parse")
    func quotedBoundary() throws {
        let raw =
            "preamble\r\n"
            + "--abc def\r\n"
            + "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n"
            + "un vélo; \"rouge\"\r\n"
            + "--abc def\r\n"
            + "content-disposition: form-data; name=\"empty\"; filename=\"e;1.png\"\r\n\r\n"
            + "\r\n"
            + "--abc def--\r\n"
        let form = try MultipartForm(
            contentType: "multipart/form-data; charset=utf-8; boundary=\"abc def\"",
            body: Data(raw.utf8)
        )
        #expect(form.field("prompt") == "un vélo; \"rouge\"")
        let empty = try #require(form.file("empty"))
        #expect(empty.filename == "e;1.png")
        #expect(empty.contentType == nil)
        #expect(empty.data.isEmpty)
    }

    @Test(
        "Malformed bodies throw a 400 invalid_request_error",
        arguments: [
            ("application/json", "--b\r\n\r\nx\r\n--b--"),
            ("multipart/form-data", "--b\r\n\r\nx\r\n--b--"),
            ("multipart/form-data; boundary=b", "no boundary here"),
            ("multipart/form-data; boundary=b", "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nx"),
            ("multipart/form-data; boundary=b", "--b\r\nContent-Disposition: form-data\r\n\r\nx\r\n--b--"),
            ("multipart/form-data; boundary=b", "--b\r\nContent-Disposition: form-data; name=\"a\"\r\nx\r\n--b--"),
            ("multipart/form-data; boundary=b", "--bx"),
        ]
    )
    func malformed(contentType: String, body: String) {
        #expect {
            try MultipartForm(contentType: contentType, body: Data(body.utf8))
        } throws: { error in
            guard let error = error as? OpenAIError else { return false }
            return error.status == .badRequest && error.type == "invalid_request_error"
        }
    }
}
