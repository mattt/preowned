import Foundation

/// Builds a `multipart/form-data` body for tests.
struct FormDataBuilder {
    let boundary = "preowned-test-boundary"
    private(set) var data = Data()

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// The body with its closing boundary.
    var body: Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }

    func field(_ name: String, _ value: String) -> FormDataBuilder {
        var copy = self
        copy.data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
        copy.data += Data("\(value)\r\n".utf8)
        return copy
    }

    func file(
        _ name: String,
        filename: String,
        contentType: String = "application/octet-stream",
        data fileData: Data
    ) -> FormDataBuilder {
        var copy = self
        copy.data += Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                + "Content-Type: \(contentType)\r\n\r\n").utf8
        )
        copy.data += fileData + Data("\r\n".utf8)
        return copy
    }
}
