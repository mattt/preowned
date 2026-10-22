import Foundation
import ImagePlayground
import Testing

@testable import PreownedKit

@Suite("ImageCreator service")
struct ImageCreatorServiceTests {
    @Test("ImageCreator errors map to OpenAI errors")
    func errorMapping() {
        #expect(ImageCreatorService.openAIError(for: .notSupported).status == .serviceUnavailable)
        #expect(ImageCreatorService.openAIError(for: .notSupported).code == "service_unavailable")
        #expect(ImageCreatorService.openAIError(for: .backgroundCreationForbidden).status == .serviceUnavailable)
        #expect(ImageCreatorService.openAIError(for: .unsupportedInputImage).param == "image")
        #expect(ImageCreatorService.openAIError(for: .unsupportedLanguage).param == "prompt")
        #expect(ImageCreatorService.openAIError(for: .creationFailed).status == .internalServerError)
    }

    @Test("The unavailable reason points to the window modes")
    func reason() {
        let reason = ImageCreatorService.reason(for: ImageCreator.Error.notSupported)
        #expect(reason.hasPrefix("ImageCreator is not supported for this process."))
        #expect(reason.contains("--images=interactive"))
    }

    @Test("Style names leave out the external provider")
    func styleNames() {
        let names = ImagePlaygroundSupport.styleNames(ImagePlaygroundStyle.all)
        #expect(names.contains("illustration"))
        #expect(!names.contains(ImagePlaygroundSupport.externalProviderID))
        #expect(ImagePlaygroundSupport.style(named: "z_external_provider", in: ImagePlaygroundStyle.all) == nil)
        #expect(ImagePlaygroundSupport.style(named: "sketch", in: ImagePlaygroundStyle.all) == .sketch)
    }

    @Test("PNG data round-trips, and other formats convert to PNG")
    func png() throws {
        let image = try ImagePlaygroundSupport.cgImage(from: samplePNG)
        #expect(image.width == 2)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pngURL = directory.appending(path: "a.png")
        try samplePNG.write(to: pngURL)
        #expect(try ImagePlaygroundSupport.pngData(fromFile: pngURL) == samplePNG)
        #expect(throws: OpenAIError.self) {
            try ImagePlaygroundSupport.pngData(fromFile: directory.appending(path: "missing.png"))
        }
    }
}

/// Tests that call Image Playground.
///
/// They run only when `PREOWNED_LIVE_TESTS=1`.
/// On macOS 27, `ImageCreator` is unavailable,
/// so the test checks the reason instead of creating an image.
@Suite(
    "Live Image Playground",
    .enabled(if: ProcessInfo.processInfo.environment["PREOWNED_LIVE_TESTS"] == "1")
)
struct LiveImageTests {
    @Test("ImageCreator creates an image or explains why not")
    func creator() async throws {
        let service = await ImageCreatorService.probe()
        guard service.availability == .available else {
            #expect(service.availability.reason?.contains("--images=") == true)
            return
        }
        let images = try await service.generateImages(ImageGenerationRequest(prompt: "a red bicycle"))
        #expect(images.count == 1)
        _ = try ImagePlaygroundSupport.cgImage(from: images[0].pngData)
    }
}
