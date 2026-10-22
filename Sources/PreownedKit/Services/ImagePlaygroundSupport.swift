import CoreGraphics
import Foundation
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers

/// Conversions that both Image Playground services share.
enum ImagePlaygroundSupport {
    /// The style that sends prompts to an outside provider, such as ChatGPT.
    /// preowned leaves it out, because it is not on-device.
    static let externalProviderID = "z_external_provider"

    /// The names of the styles that a request can use.
    static func styleNames(_ styles: [ImagePlaygroundStyle]) -> [String] {
        styles.map(\.id).filter { $0 != externalProviderID }
    }

    /// The style with a name from ``styleNames(_:)``.
    static func style(named name: String?, in styles: [ImagePlaygroundStyle]) -> ImagePlaygroundStyle? {
        guard let name, name != externalProviderID else { return nil }
        return styles.first { $0.id == name }
    }

    /// The concept for a text prompt, as ``ImagePromptConcept`` decides.
    static func concept(for prompt: String) -> ImagePlaygroundConcept {
        switch ImagePromptConcept(prompt: prompt) {
        case .text: .text(prompt)
        case .extracted: .extracted(from: prompt, title: nil)
        }
    }

    /// Decodes image data.
    static func cgImage(from data: Data) throws(OpenAIError) -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw .invalidRequest("Invalid image file.", param: "image", code: "invalid_image")
        }
        return image
    }

    /// Encodes an image as PNG.
    static func pngData(from image: CGImage) throws(OpenAIError) -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil
            )
        else {
            throw .server("Could not encode the image as PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw .server("Could not encode the image as PNG.")
        }
        return data as Data
    }

    /// Reads an image file and returns PNG data,
    /// converting it if the file has another format.
    static func pngData(fromFile url: URL) throws(OpenAIError) -> Data {
        guard let data = try? Data(contentsOf: url) else {
            throw .server("Could not read the image that Image Playground created.")
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) as String? == UTType.png.identifier
        {
            return data
        }
        return try pngData(from: cgImage(from: data))
    }
}
