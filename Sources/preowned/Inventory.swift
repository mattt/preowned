import ArgumentParser
import PreownedKit

struct Inventory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the capabilities that this Mac can serve."
    )

    func run() async throws {
        let services = ServiceRegistry.system()
        for (capability, line) in zip(Capability.allCases, Self.lines(for: services)) {
            print(line)
            for detail in await services.inventoryDetails(of: capability) {
                print("    \(detail)")
            }
        }
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
