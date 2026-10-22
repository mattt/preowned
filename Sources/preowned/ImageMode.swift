import ArgumentParser
import PreownedKit

/// How `serve` creates images, from `--images`.
enum ImageMode: String, CaseIterable, ExpressibleByArgument {
    /// `ImageCreator` without UI, which works on macOS 26.
    case `default`

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }

    /// The image service for this mode.
    func makeService() async -> any ImageService {
        switch self {
        case .default:
            await ImageCreatorService.probe()
        }
    }
}
