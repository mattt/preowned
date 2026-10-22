import CoreGraphics
import Foundation
import Hummingbird
import HummingbirdTesting
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import PreownedKit

/// An image service that returns canned PNGs and records requests.
final class FakeImageService: ImageService {
    let availability: ServiceAvailability
    let availableStyles: [String]
    let error: OpenAIError?
    let delay: Duration
    let maximumCount: Int
    private let state = Mutex<(requests: [ImageGenerationRequest], running: Int, maximumRunning: Int)>(
        ([], 0, 0)
    )

    init(
        availability: ServiceAvailability = .available,
        availableStyles: [String] = ["animation", "illustration", "sketch"],
        error: OpenAIError? = nil,
        delay: Duration = .zero,
        maximumCount: Int = ImageCount.maximum
    ) {
        self.availability = availability
        self.availableStyles = availableStyles
        self.error = error
        self.delay = delay
        self.maximumCount = maximumCount
    }

    var requests: [ImageGenerationRequest] {
        state.withLock { $0.requests }
    }

    /// The most generations that ran at the same time.
    var maximumRunning: Int {
        state.withLock { $0.maximumRunning }
    }

    func generateImages(_ request: ImageGenerationRequest) async throws -> [GeneratedImage] {
        state.withLock {
            $0.requests.append(request)
            $0.running += 1
            $0.maximumRunning = max($0.maximumRunning, $0.running)
        }
        defer { state.withLock { $0.running -= 1 } }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
        return (0..<request.count).map { index in GeneratedImage(pngData: Data("png-\(index)".utf8)) }
    }
}

/// A 2x2 PNG image.
let samplePNG: Data = {
    let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}()

extension TestClientProtocol {
    /// Posts a multipart body.
    func post(
        _ uri: String,
        form: FormDataBuilder,
        _ callback: @escaping (TestResponse) async throws -> Void
    ) async throws {
        try await execute(
            uri: uri,
            method: .post,
            headers: [.contentType: form.contentType],
            body: ByteBuffer(bytes: form.body),
            testCallback: callback
        )
    }
}

@Suite("Image endpoints")
struct ImageRoutesTests {
    @Test("A generation returns b64_json images and maps the parameters")
    func generation() async throws {
        let service = FakeImageService()
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post(
                "/v1/images/generations",
                json: #"{"model": "dall-e-3", "prompt": "a red bicycle", "n": 2, "style": "vivid", "#
                    + #""size": "1024x1792", "quality": "hd"}"#
            ) { response in
                #expect(response.status == .ok)
                let body = try response.decode(ImagesResponse.self)
                #expect(body.created > 0)
                #expect(body.data.count == 2)
                #expect(body.data[0].b64JSON == Data("png-0".utf8).base64EncodedString())
                #expect(body.data[0].url == nil)
                #expect(!response.text.contains("\"url\""))
            }
        }
        #expect(
            service.requests == [
                ImageGenerationRequest(
                    prompt: "a red bicycle",
                    count: 2,
                    style: "animation",
                    size: ImageSize(width: 1024, height: 1792)
                )
            ]
        )
    }

    @Test("response_format url returns data URLs")
    func dataURL() async throws {
        try await withServer(ServiceRegistry(images: FakeImageService())) { client in
            try await client.post(
                "/v1/images/generations",
                json: #"{"prompt": "a cat", "response_format": "url", "style": "natural", "size": "auto"}"#
            ) { response in
                let body = try response.decode(ImagesResponse.self)
                let expected = "data:image/png;base64," + Data("png-0".utf8).base64EncodedString()
                #expect(body.data == [ImageObject(url: expected)])
            }
        }
    }

    @Test(
        "Invalid parameters return 400 with the parameter name",
        arguments: [
            (#"{"prompt": "a cat", "n": 0}"#, "n"),
            (#"{"prompt": "a cat", "n": 11}"#, "n"),
            (#"{"prompt": "a cat", "response_format": "png"}"#, "response_format"),
            (#"{"prompt": "a cat", "size": "big"}"#, "size"),
            (#"{"prompt": "a cat", "size": "0x10"}"#, "size"),
            (#"{"prompt": "a cat", "style": "oil"}"#, "style"),
            (#"{"prompt": ""}"#, "prompt"),
            (#"{"prompt": "a cat", "model": "apple-foundation-model"}"#, "model"),
        ]
    )
    func invalidParameters(json: String, param: String) async throws {
        let service = FakeImageService()
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/generations", json: json) { response in
                #expect(response.status == .badRequest)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                #expect(error.param == param)
            }
        }
        #expect(service.requests.isEmpty)
    }

    @Test("stream true returns 400 unsupported_parameter, and stream false is accepted")
    func stream() async throws {
        let service = FakeImageService()
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/generations", json: #"{"prompt": "a", "stream": true}"#) {
                response in
                #expect(response.status == .badRequest)
                #expect(response.error?.param == "stream")
                #expect(response.error?.code == "unsupported_parameter")
            }
            let form = FormDataBuilder().field("prompt", "a").field("stream", "true")
                .file("image", filename: "a.png", data: samplePNG)
            try await client.post("/v1/images/edits", form: form) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.param == "stream")
                #expect(response.error?.code == "unsupported_parameter")
            }
            try await client.post("/v1/images/generations", json: #"{"prompt": "a", "stream": false}"#) {
                response in
                #expect(response.status == .ok)
            }
        }
        #expect(service.requests.count == 1)
    }

    @Test("A missing prompt names the parameter")
    func missingPrompt() async throws {
        try await withServer(ServiceRegistry(images: FakeImageService())) { client in
            try await client.post("/v1/images/generations", json: #"{"n": 1}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.message == "Missing required parameter: 'prompt'.")
            }
        }
    }

    @Test("A style that the service lacks lists the accepted styles")
    func styleList() async throws {
        let service = FakeImageService(availableStyles: ["illustration", "sketch"])
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/generations", json: #"{"prompt": "a", "style": "vivid"}"#) {
                response in
                #expect(response.status == .badRequest)
                #expect(
                    response.error?.message
                        == "Invalid value for 'style': 'vivid'. "
                        + "Supported values are: 'illustration', 'sketch', 'natural'."
                )
            }
        }
    }

    @Test("Strict mode rejects an unknown model name")
    func strictModel() async throws {
        try await withServer(
            ServiceRegistry(images: FakeImageService()),
            configuration: ServerConfiguration(strictModels: true)
        ) { client in
            try await client.post("/v1/images/generations", json: #"{"prompt": "a", "model": "dall-e-3"}"#) {
                response in
                #expect(response.status == .notFound)
                #expect(response.error?.code == "model_not_found")
            }
            try await client.post(
                "/v1/images/generations",
                json: #"{"prompt": "a", "model": "apple-image-playground"}"#
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("Without an image service, the endpoints return 503 and /v1/models leaves images out")
    func unavailable() async throws {
        let reason = "ImageCreator is not available to this process."
        for services in [
            ServiceRegistry(),
            ServiceRegistry(images: FakeImageService(availability: .unavailable(reason: reason))),
        ] {
            try await withServer(services) { client in
                try await client.post("/v1/images/generations", json: #"{"prompt": "a"}"#) { response in
                    #expect(response.status == .serviceUnavailable)
                    let error = try #require(response.error)
                    #expect(error.type == "server_error")
                    #expect(error.code == "service_unavailable")
                    #expect(response.headers[.shouldRetry] == "false")
                }
                let form = FormDataBuilder().file("image", filename: "a.png", data: samplePNG)
                try await client.post("/v1/images/variations", form: form) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.headers[.shouldRetry] == "false")
                }
                try await client.execute(uri: "/v1/models", method: .get) { response in
                    let decoded = try response.decode(ModelList.self)
                    #expect(decoded.data.isEmpty)
                }
            }
        }
    }

    @Test("An available image service appears in /v1/models")
    func listed() async throws {
        try await withServer(ServiceRegistry(images: FakeImageService())) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                let decoded = try response.decode(ModelList.self)
                #expect(decoded.data.map(\.id) == ["apple-image-playground"])
            }
        }
    }

    @Test("A service error passes through in OpenAI's format")
    func serviceError() async throws {
        let cancelled = OpenAIError.invalidRequest(
            "The person at the Mac cancelled the image.",
            code: "image_generation_cancelled"
        )
        try await withServer(ServiceRegistry(images: FakeImageService(error: cancelled))) { client in
            try await client.post("/v1/images/generations", json: #"{"prompt": "a"}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.code == "image_generation_cancelled")
            }
        }
    }

    @Test("A service with a lower image limit rejects a larger n with the reason")
    func countLimit() async throws {
        let service = FakeImageService(maximumCount: 4)
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/generations", json: #"{"prompt": "a", "n": 5}"#) { response in
                #expect(response.status == .badRequest)
                let error = try #require(response.error)
                #expect(error.param == "n")
                #expect(error.code == "invalid_value")
                #expect(error.message.contains("at most 4"))
            }
            try await client.post("/v1/images/generations", json: #"{"prompt": "a", "n": 4}"#) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(service.requests.map(\.count) == [4])
    }

    @Test("An edit sends the image and prompt to the service")
    func edit() async throws {
        let service = FakeImageService()
        let form = FormDataBuilder()
            .field("prompt", "add a hat")
            .file("image[]", filename: "a.png", contentType: "image/png", data: samplePNG)
            .field("n", "1")
            .field("style", "sketch")
            .field("model", "gpt-image-1")
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/edits", form: form) { response in
                #expect(response.status == .ok)
                let decoded = try response.decode(ImagesResponse.self)
                #expect(decoded.data.count == 1)
            }
        }
        #expect(
            service.requests == [
                ImageGenerationRequest(prompt: "add a hat", sourceImage: samplePNG, count: 1, style: "sketch")
            ]
        )
    }

    @Test("A variation sends only the image")
    func variation() async throws {
        let service = FakeImageService()
        let form = FormDataBuilder()
            .file("image", filename: "a.png", data: samplePNG)
            .field("n", "3")
            .field("response_format", "b64_json")
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/variations", form: form) { response in
                #expect(response.status == .ok)
                let decoded = try response.decode(ImagesResponse.self)
                #expect(decoded.data.count == 3)
            }
        }
        #expect(service.requests == [ImageGenerationRequest(prompt: "", sourceImage: samplePNG, count: 3)])
    }

    @Test(
        "Invalid edits return 400 with the parameter name",
        arguments: [
            (
                FormDataBuilder().field("prompt", "a").file("image", filename: "a.png", data: samplePNG)
                    .file("mask", filename: "m.png", data: samplePNG),
                "mask"
            ),
            (FormDataBuilder().field("prompt", "a"), "image"),
            (
                FormDataBuilder().field("prompt", "a").file("image[]", filename: "a.png", data: samplePNG)
                    .file("image[]", filename: "b.png", data: samplePNG),
                "image"
            ),
            (FormDataBuilder().field("prompt", "a").file("image", filename: "a.png", data: Data("no".utf8)), "image"),
            (FormDataBuilder().file("image", filename: "a.png", data: samplePNG), "prompt"),
            (
                FormDataBuilder().field("prompt", "a").field("n", "two")
                    .file("image", filename: "a.png", data: samplePNG),
                "n"
            ),
        ]
    )
    func invalidEdits(form: FormDataBuilder, param: String) async throws {
        let service = FakeImageService()
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/edits", form: form) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.param == param)
            }
        }
        #expect(service.requests.isEmpty)
    }

    @Test("A body that is not multipart returns 415")
    func notMultipart() async throws {
        try await withServer(ServiceRegistry(images: FakeImageService())) { client in
            try await client.post("/v1/images/edits", json: #"{"prompt": "a"}"#) { response in
                #expect(response.status == .unsupportedMediaType)
                #expect(response.error?.type == "invalid_request_error")
            }
        }
    }

    @Test("An upload over the image body limit returns 413")
    func uploadTooLarge() async throws {
        let service = FakeImageService()
        let form = FormDataBuilder()
            .file("image", filename: "a.png", data: Data(count: ImageRoutes.maximumBodySize))
        try await withServer(ServiceRegistry(images: service)) { client in
            try await client.post("/v1/images/variations", form: form) { response in
                #expect(response.status == .contentTooLarge)
                #expect(response.error?.type == "invalid_request_error")
            }
        }
        #expect(service.requests.isEmpty)
    }

    @Test("A Content-Length over the limit fails before the server reads the body")
    func declaredLengthTooLarge() async throws {
        var request = Request(
            head: HTTPRequest(
                method: .post,
                scheme: "http",
                authority: "localhost",
                path: "/v1/images/edits",
                headerFields: [.contentLength: "\(ImageRoutes.maximumBodySize + 1)"]
            ),
            // The empty body shows that the declared length alone fails the request.
            body: RequestBody(buffer: ByteBuffer())
        )
        await #expect(throws: OpenAIError.self) {
            _ = try await request.collectBody(limitedTo: ImageRoutes.maximumBodySize)
        }
    }

    @Test("Concurrent requests run one generation at a time")
    func oneAtATime() async throws {
        let service = FakeImageService(delay: .milliseconds(30))
        try await withServer(ServiceRegistry(images: service)) { client in
            try await withThrowingTaskGroup { group in
                for _ in 0..<4 {
                    group.addTask {
                        try await client.post("/v1/images/generations", json: #"{"prompt": "a"}"#) { response in
                            #expect(response.status == .ok)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(service.requests.count == 4)
        #expect(service.maximumRunning == 1)
    }
}

@Suite("Image parameter mapping")
struct ImageParameterTests {
    @Test("A prompt above the threshold becomes an extracted concept")
    func concept() {
        let short = String(repeating: "a", count: ImagePromptConcept.extractionThreshold)
        #expect(ImagePromptConcept(prompt: short) == .text)
        #expect(ImagePromptConcept(prompt: short + "b") == .extracted)
    }

    @Test("Style names map case-insensitively, with OpenAI aliases")
    func styles() throws {
        let available = ["animation", "illustration", "sketch"]
        #expect(try ImageStyleMapping.resolve(nil, available: available) == nil)
        #expect(try ImageStyleMapping.resolve("Sketch", available: available) == "sketch")
        #expect(try ImageStyleMapping.resolve("vivid", available: available) == "animation")
        #expect(try ImageStyleMapping.resolve("natural", available: available) == "illustration")
        #expect(throws: OpenAIError.self) { try ImageStyleMapping.resolve("emoji", available: available) }
    }

    @Test("Sizes parse as WIDTHxHEIGHT or auto")
    func sizes() throws {
        #expect(try ImageSize(parsing: nil) == nil)
        #expect(try ImageSize(parsing: "auto") == nil)
        #expect(try ImageSize(parsing: "256x512") == ImageSize(width: 256, height: 512))
        #expect(throws: OpenAIError.self) { try ImageSize(parsing: "256x") }
    }

    @Test("A full queue rejects a caller with 429 and no retry")
    func queueLimit() async throws {
        let queue = GenerationQueue(maximumWaiters: 1)
        let isReleased = Mutex(false)
        let hasStarted = Mutex(false)
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await queue.run {
                    hasStarted.withLock { $0 = true }
                    while !isReleased.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
            }
            while !hasStarted.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(1))
            }
            group.addTask { try await queue.run {} }
            while await queue.waitingCount < 1 {
                try await Task.sleep(for: .milliseconds(1))
            }
            do {
                try await queue.run {}
                Issue.record("The third caller ran.")
            } catch let error as OpenAIError {
                #expect(error.status == .tooManyRequests)
                #expect(error.shouldRetry == false)
            }
            isReleased.withLock { $0 = true }
            try await group.waitForAll()
        }
    }

    @Test("The queue hands turns over in arrival order")
    func queueOrder() async throws {
        let queue = GenerationQueue()
        let order = Mutex<[Int]>([])
        let isReleased = Mutex(false)
        let hasStarted = Mutex(false)
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await queue.run {
                    hasStarted.withLock { $0 = true }
                    while !isReleased.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    order.withLock { $0.append(0) }
                }
            }
            for index in 1...2 {
                // Wait until the earlier callers hold or wait for the turn.
                while await queue.waitingCount < index - 1 || !hasStarted.withLock({ $0 }) {
                    try await Task.sleep(for: .milliseconds(1))
                }
                group.addTask {
                    try await queue.run { order.withLock { $0.append(index) } }
                }
            }
            while await queue.waitingCount < 2 {
                try await Task.sleep(for: .milliseconds(1))
            }
            isReleased.withLock { $0 = true }
            try await group.waitForAll()
        }
        #expect(order.withLock { $0 } == [0, 1, 2])
    }
}
