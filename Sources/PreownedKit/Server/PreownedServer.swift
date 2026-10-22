import Foundation
import Hummingbird

/// Settings for the HTTP server.
public struct ServerConfiguration: Sendable {
    public var host: String
    public var port: Int
    /// The bearer token that requests must send, or `nil` to accept any token.
    public var apiKey: String?
    /// Whether to reject model names other than the canonical IDs.
    public var strictModels: Bool

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 8027

    public init(
        host: String = defaultHost,
        port: Int = defaultPort,
        apiKey: String? = nil,
        strictModels: Bool = false
    ) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.strictModels = strictModels
    }
}

/// The OpenAI-compatible HTTP server.
public enum PreownedServer {
    /// The largest request body that the server reads, in bytes.
    ///
    /// Images in chat messages arrive as base64 `data:` URLs,
    /// so the limit is larger than a text-only API needs.
    public static let maximumBodySize = 32 * 1024 * 1024

    /// Builds the application.
    public static func application(
        services: ServiceRegistry,
        configuration: ServerConfiguration,
        onServerRunning: @escaping @Sendable () async -> Void = {}
    ) -> some ApplicationProtocol {
        Application(
            router: router(services: services, configuration: configuration),
            configuration: ApplicationConfiguration(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "preowned"
            ),
            onServerRunning: { _ in await onServerRunning() }
        )
    }

    /// Builds the router with every route and middleware.
    public static func router(
        services: ServiceRegistry,
        configuration: ServerConfiguration
    ) -> Router<BasicRequestContext> {
        let router = Router()
        // Middleware applies only to routes added after it.
        router.add(middleware: OpenAIErrorMiddleware())
        router.add(middleware: BearerTokenMiddleware(apiKey: configuration.apiKey))

        let resolver = ModelResolver(isStrict: configuration.strictModels)
        ModelRoutes(services: services).register(on: router)
        ChatRoutes(services: services, resolver: resolver).register(on: router)
        return router
    }
}

// MARK: - Helpers

extension Request {
    /// Decodes a JSON body, with OpenAI errors for a bad body.
    mutating func decodeJSON<T: Decodable>(_ type: T.Type) async throws -> T {
        let buffer: ByteBuffer
        do {
            buffer = try await collectBody(upTo: PreownedServer.maximumBodySize)
        } catch {
            throw OpenAIError(
                status: .contentTooLarge,
                message: "The request body is larger than \(PreownedServer.maximumBodySize) bytes.",
                type: "invalid_request_error"
            )
        }
        do {
            return try JSONCoding.decoder.decode(T.self, from: Data(buffer: buffer))
        } catch let error as DecodingError {
            throw OpenAIError.invalidRequest(Self.describe(error))
        } catch {
            throw OpenAIError.invalidRequest(
                "We could not parse the JSON body of your request. "
                    + "The OpenAI API expects a JSON payload."
            )
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
            }
            .joined()
            .trimmingPrefix(".")
            .description
        }
        switch error {
        case .keyNotFound(let key, let context):
            let location = path(context.codingPath + [key])
            return "Missing required parameter: '\(location)'."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "Invalid type for '\(path(context.codingPath))'."
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty {
                return "We could not parse the JSON body of your request. "
                    + "The OpenAI API expects a JSON payload."
            }
            return "Invalid value for '\(path(context.codingPath))'."
        @unknown default:
            return "We could not parse the JSON body of your request."
        }
    }
}

extension Response {
    /// A 200 response with a JSON body.
    static func json(_ value: some Encodable) throws -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: try JSONCoding.encoder.encode(value)))
        )
    }
}
