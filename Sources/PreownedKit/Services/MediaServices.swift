import Foundation

// These protocols define the capabilities that later phases implement.
// The server registers no routes for them yet,
// so `GET /v1/models` leaves their models out
// and their endpoints return OpenAI's 404 for an unknown URL.
// A phase that adds an implementation also adds its routes.

// MARK: - Images

/// A service that creates images, as Image Playground does.
public protocol ImageService: Sendable {
    var availability: ServiceAvailability { get }

    /// The style names that the service accepts.
    var availableStyles: [String] { get }

    /// Creates images from a text prompt and an optional source image.
    func generateImages(_ request: ImageGenerationRequest) async throws -> [GeneratedImage]
}

/// A request to create images.
public struct ImageGenerationRequest: Sendable, Equatable {
    public var prompt: String
    /// Encoded source image data for edits and variations.
    public var sourceImage: Data?
    public var count: Int
    public var style: String?

    public init(prompt: String, sourceImage: Data? = nil, count: Int = 1, style: String? = nil) {
        self.prompt = prompt
        self.sourceImage = sourceImage
        self.count = count
        self.style = style
    }
}

/// An image that a service created.
public struct GeneratedImage: Sendable, Equatable {
    /// PNG data.
    public var pngData: Data

    public init(pngData: Data) {
        self.pngData = pngData
    }
}
