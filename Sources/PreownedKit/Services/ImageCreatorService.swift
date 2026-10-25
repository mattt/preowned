import Foundation
import ImagePlayground

/// Creates images without UI through Image Playground's `ImageCreator`.
///
/// `ImageCreator` works on macOS 26.
/// On macOS 27, it throws `notSupported` for third-party processes,
/// so the service reports itself unavailable
/// and the image endpoints return 503.
public final class ImageCreatorService: ImageService {
    public let availability: ServiceAvailability
    public let availableStyles: [String]
    private let creator: ImageCreator?

    /// The style for a request without one.
    static let defaultStyle = "illustration"

    private init(creator: ImageCreator?, availability: ServiceAvailability) {
        self.creator = creator
        self.availability = availability
        self.availableStyles = creator.map { ImagePlaygroundSupport.styleNames($0.availableStyles) } ?? []
    }

    /// Creates an `ImageCreator` once
    /// and returns a service that reports whether it worked.
    public static func probe() async -> ImageCreatorService {
        do {
            return ImageCreatorService(creator: try await ImageCreator(), availability: .available)
        } catch {
            return ImageCreatorService(creator: nil, availability: .unavailable(reason: reason(for: error)))
        }
    }

    /// The reason that `ImageCreator()` failed, for `inventory` and 503 errors.
    static func reason(for error: any Error) -> String {
        let detail =
            switch error as? ImageCreator.Error {
            case .notSupported?: "ImageCreator is not supported for this process"
            case .unavailable?: "Image Playground is unavailable; check that Apple Intelligence is on"
            default: "ImageCreator failed: \(error.localizedDescription)"
            }
        return detail
            + ". On macOS 27, run `preowned serve --images=interactive` or `--images=auto-approve`"
            + " to use the Image Playground window."
    }

    public func generateImages(_ request: ImageGenerationRequest) async throws -> [GeneratedImage] {
        guard let creator else {
            throw OpenAIError.serviceUnavailable(availability.reason ?? "ImageCreator is unavailable.")
        }
        var concepts: [ImagePlaygroundConcept] = []
        if let source = request.sourceImage {
            concepts.append(.image(try ImagePlaygroundSupport.cgImage(from: source)))
        }
        if !request.prompt.isEmpty {
            concepts.append(ImagePlaygroundSupport.concept(for: request.prompt))
        }
        let style =
            ImagePlaygroundSupport.style(named: request.style, in: creator.availableStyles)
            ?? ImagePlaygroundSupport.style(named: Self.defaultStyle, in: creator.availableStyles)
            ?? .illustration

        var images: [GeneratedImage] = []
        do {
            for try await created in creator.images(for: concepts, style: style, limit: request.count) {
                images.append(GeneratedImage(pngData: try ImagePlaygroundSupport.pngData(from: created.cgImage)))
            }
        } catch let error as ImageCreator.Error {
            throw Self.openAIError(for: error)
        }
        return images
    }

    /// Maps an `ImageCreator` error to an OpenAI error.
    static func openAIError(for error: ImageCreator.Error) -> OpenAIError {
        let message = error.localizedDescription
        switch error {
        case .notSupported, .unavailable, .backgroundCreationForbidden:
            return .serviceUnavailable(message)
        case .faceInImageTooSmall, .unsupportedInputImage:
            return .invalidRequest(message, param: "image", code: "invalid_image")
        case .unsupportedLanguage, .conceptsRequirePersonIdentity:
            return .invalidRequest(message, param: "prompt", code: "invalid_value")
        case .creationCancelled, .creationFailed:
            return .server(message)
        @unknown default:
            return .server(message)
        }
    }
}
