import ArgumentParser

@main
struct Preowned: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preowned",
        abstract: "An OpenAI-compatible API for the models already on your Mac.",
        version: "0.1.0",
        subcommands: [Serve.self, Inventory.self]
    )
}
