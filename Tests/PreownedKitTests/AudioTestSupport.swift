import Foundation
import Hummingbird
import HummingbirdTesting
import Synchronization

@testable import PreownedKit

/// A transcription service that returns a canned transcription and records requests.
final class FakeTranscriptionService: TranscriptionService {
    let availability: ServiceAvailability
    let result: Result<Transcription, OpenAIError>
    private let requests = Mutex<[(TranscriptionRequest, translated: Bool)]>([])

    static let sample = Transcription(
        text: "Hello from the lot. We have GPT at home.",
        language: "en-US",
        duration: 1.72,
        segments: [
            .init(start: 0, end: 1.14, text: "Hello from the lot.", confidence: 0.5),
            .init(start: 1.14, end: 1.72, text: " We have GPT at home."),
        ],
        words: [
            .init(word: "Hello", start: 0, end: 0.24),
            .init(word: "from", start: 0.24, end: 0.5),
        ]
    )

    init(
        availability: ServiceAvailability = .available,
        result: Result<Transcription, OpenAIError> = .success(sample)
    ) {
        self.availability = availability
        self.result = result
    }

    var lastRequest: (TranscriptionRequest, translated: Bool)? {
        requests.withLock { $0.last }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> Transcription {
        requests.withLock { $0.append((request, false)) }
        return try result.get()
    }

    func translate(_ request: TranscriptionRequest) async throws -> Transcription {
        requests.withLock { $0.append((request, true)) }
        var transcription = try result.get()
        transcription.language = "en"
        return transcription
    }
}

/// A builder for `multipart/form-data` bodies in tests.
struct MultipartBody {
    static let boundary = "preowned-test-boundary"
    private(set) var data = Data()

    static var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    func field(_ name: String, _ value: String) -> MultipartBody {
        var copy = self
        copy.data.append(Data("--\(Self.boundary)\r\n".utf8))
        copy.data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        copy.data.append(Data(value.utf8))
        copy.data.append(Data("\r\n".utf8))
        return copy
    }

    func file(
        _ name: String,
        filename: String = "speech.wav",
        contentType: String = "audio/wav",
        data fileData: Data = Data("RIFF".utf8)
    ) -> MultipartBody {
        var copy = self
        copy.data.append(Data("--\(Self.boundary)\r\n".utf8))
        copy.data.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
            )
        )
        copy.data.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        copy.data.append(fileData)
        copy.data.append(Data("\r\n".utf8))
        return copy
    }

    var finished: ByteBuffer {
        var data = self.data
        data.append(Data("--\(Self.boundary)--\r\n".utf8))
        return ByteBuffer(bytes: data)
    }
}

extension TestClientProtocol {
    /// Posts a multipart body.
    func post(
        _ uri: String,
        multipart body: MultipartBody,
        _ callback: @escaping (TestResponse) async throws -> Void = { _ in }
    ) async throws {
        try await execute(
            uri: uri,
            method: .post,
            headers: [.contentType: MultipartBody.contentType],
            body: body.finished,
            testCallback: callback
        )
    }
}
