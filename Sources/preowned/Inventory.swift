import ArgumentParser
import PreownedKit

struct Inventory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the capabilities that this Mac can serve."
    )

    @Option(name: .customLong("images"), help: "The image mode to check.")
    var imageMode: ImageMode = .default

    func run() async throws {
        for line in Self.lines(for: .system(images: await imageMode.makeService())) {
            print(line)
        }
        print(ImageMode.accessibilityLine)
    }

    /// One line for each capability, with its model ID and status.
    static func lines(for services: ServiceRegistry) -> [String] {
        let width = Capability.allCases.map(\.modelID.count).max() ?? 0
        return Capability.allCases.map { capability in
            let id = capability.modelID.padding(toLength: width, withPad: " ", startingAt: 0)
            let status =
                switch services.availability(of: capability) {
                case .available: "available"
                case .unavailable(let reason): "unavailable: \(reason)"
                }
            return "\(id)  \(capability.displayName) (\(capability.framework)): \(status)"
        }
    }
}
