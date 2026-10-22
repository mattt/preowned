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

    @Option(
        name: .customLong("allow-origin"),
        help: ArgumentHelp(
            "A browser origin, such as http://localhost:5173, whose requests the server accepts.",
            discussion: "Repeat the option for more origins. "
                + "Without it, the server rejects every request with an Origin header.",
            valueName: "origin"
        )
    )
    var allowedOrigins: [String] = []

    @Option(name: .customLong("images"), help: "How to create images.")
    var imageMode: ImageMode = .default

    @Option(help: "Seconds to wait for each image in the interactive and auto-approve modes.")
    var imageTimeout: Int = 120

    @Flag(
        help: ArgumentHelp(
            "Let services download the speech and embedding assets that a request needs.",
            discussion: "Without it, a request that needs a missing asset returns 503."
        )
    )
    var allowAssetDownloads: Bool = false

    func run() async throws {
        if imageMode == .autoApprove {
            AccessibilityApprover.requestTrust()
        }
        let images = await imageMode.makeService(timeout: .seconds(imageTimeout))
        let services = ServiceRegistry.system(
            images: images,
            allowAssetDownloads: allowAssetDownloads
        )
        let configuration = ServerConfiguration(
            host: host,
            port: port,
            apiKey: apiKey,
            strictModels: strictModels,
            allowedOrigins: allowedOrigins
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
                if imageMode == .autoApprove {
                    print("  \(ImageMode.accessibilityLine)")
                }
            }
        )
        if imageMode.usesWindow {
            WindowHost.startApplication()
        }
        try await app.runService()
    }
}
