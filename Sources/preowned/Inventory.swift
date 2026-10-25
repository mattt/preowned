import ArgumentParser
import PreownedKit

struct Inventory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the capabilities that this Mac can serve."
    )

    @Option(name: .customLong("images"), help: "The image mode to check.")
    var imageMode: ImageMode = .default

    @OptionGroup var mp3: MP3EncoderOption

    /// The line before the capabilities in `inventory` and `serve`.
    static let heading = "Here's what's on the lot today:"

    /// The number of columns that `inventory` and `serve` wrap their lines to.
    static let width = 80

    func run() async throws {
        let services = ServiceRegistry.system(
            images: await imageMode.makeService(),
            mp3Encoder: mp3.encoder
        )
        print(Self.heading)
        for (capability, lines) in zip(Capability.allCases, Self.lines(for: services)) {
            for line in lines {
                print(line)
            }
            for detail in await services.inventoryDetails(of: capability) {
                for line in LineWrapping.wrap(detail, width: Self.width, indent: "    ", hangingIndent: "      ") {
                    print(line)
                }
            }
        }
        print(ImageMode.accessibilityLine)
    }

    /// The lines for each capability: its model ID and status,
    /// then the reason that it is unavailable, wrapped under the description.
    static func lines(for services: ServiceRegistry, indent: String = "") -> [[String]] {
        let width = Capability.allCases.map(\.modelID.count).max() ?? 0
        let hangingIndent = indent + String(repeating: " ", count: width + 2)
        return Capability.allCases.map { capability in
            let id = capability.modelID.padding(toLength: width, withPad: " ", startingAt: 0)
            let summary = "\(indent)\(id)  \(capability.displayName) (\(capability.framework))"
            switch services.availability(of: capability) {
            case .available:
                return ["\(summary): available"]
            case .unavailable(let reason):
                return ["\(summary): unavailable"]
                    + LineWrapping.wrapSentences(reason, width: Self.width, indent: hangingIndent)
            }
        }
    }
}
