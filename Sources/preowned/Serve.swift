import ArgumentParser
import Hummingbird
import PreownedKit

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the server."
    )

    @Option(help: "The host to listen on.")
    var host: String = ServerConfiguration.defaultHost

    @Option(help: "The port to listen on.")
    var port: Int = ServerConfiguration.defaultPort

    @Option(
        name: .customLong("api-key"),
        help: "A bearer token that requests must send. Without it, the server accepts any token."
    )
    var apiKey: String?

    @Flag(help: "Reject model names other than the canonical model IDs.")
    var strictModels: Bool = false

    @Option(name: .customLong("images"), help: "How to create images.")
    var imageMode: ImageMode = .default

    func run() async throws {
        let services = ServiceRegistry.system(images: await imageMode.makeService())
        let configuration = ServerConfiguration(
            host: host,
            port: port,
            apiKey: apiKey,
            strictModels: strictModels
        )
        let baseURL = "http://\(host):\(port)/v1"
        let app = PreownedServer.application(
            services: services,
            configuration: configuration,
            onServerRunning: {
                print("preowned is listening at \(baseURL)")
                for line in Inventory.lines(for: services) {
                    print("  \(line)")
                }
            }
        )
        try await app.runService()
    }
}
