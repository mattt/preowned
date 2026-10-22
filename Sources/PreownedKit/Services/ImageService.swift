import Foundation

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
    /// The text prompt, which is empty for a variation.
    public var prompt: String
    /// Encoded source image data for edits and variations.
    public var sourceImage: Data?
    public var count: Int
    /// One of the service's ``ImageService/availableStyles``,
    /// or `nil` for the service's default.
    public var style: String?
    /// The requested size, which a service may use as a hint.
    public var size: ImageSize?

    public init(
        prompt: String,
        sourceImage: Data? = nil,
        count: Int = 1,
        style: String? = nil,
        size: ImageSize? = nil
    ) {
        self.prompt = prompt
        self.sourceImage = sourceImage
        self.count = count
        self.style = style
        self.size = size
    }
}

/// An image size in pixels, from a `size` value such as `1024x1024`.
public struct ImageSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
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
