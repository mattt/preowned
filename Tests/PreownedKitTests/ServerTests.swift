import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PreownedKit

@Suite("Models, errors, and authentication")
struct ServerTests {
    @Test("GET /v1/models lists only available capabilities")
    func listsAvailableModels() async throws {
        let services = ServiceRegistry(
            chat: FakeChatService(),
            embeddings: FakeEmbeddingService()
        )
        try await withServer(services) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let list = try response.decode(ModelList.self)
                #expect(list.object == "list")
                #expect(list.data.map(\.id) == ["apple-foundation-model", "apple-nl-embedding"])
                #expect(list.data.allSatisfy { $0.object == "model" && $0.ownedBy == "apple" })
            }
        }
    }

    @Test("GET /v1/models leaves out an unavailable chat model")
    func leavesOutUnavailableModels() async throws {
        let services = ServiceRegistry(
            chat: FakeChatService(availability: .unavailable(reason: "Apple Intelligence is off."))
        )
        try await withServer(services) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                let list = try response.decode(ModelList.self)
                #expect(list.data.isEmpty)
            }
            try await client.execute(uri: "/v1/models/apple-foundation-model", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(response.error?.code == "model_not_found")
            }
        }
    }

    @Test("GET /v1/models/{id} returns one model or model_not_found")
    func retrievesModel() async throws {
        try await withServer(ServiceRegistry(chat: FakeChatService())) { client in
            try await client.execute(uri: "/v1/models/apple-foundation-model", method: .get) { response in
                #expect(response.status == .ok)
                let model = try response.decode(ModelObject.self)
                #expect(model.id == "apple-foundation-model")
            }
            try await client.execute(uri: "/v1/models/apple-nl-embedding", method: .get) { response in
                #expect(response.status == .notFound)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                #expect(error.param == "model")
                #expect(error.code == "model_not_found")
            }
        }
    }

    @Test("An unknown URL returns OpenAI's error body with explicit nulls")
    func unknownURL() async throws {
        try await withServer(ServiceRegistry()) { client in
            try await client.execute(uri: "/v1/fine_tuning/jobs", method: .post) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == "application/json")
                #expect(
                    response.text
                        == #"{"error":{"code":null,"message":"Invalid URL (POST /v1/fine_tuning/jobs)","#
                        + #""param":null,"type":"invalid_request_error"}}"#
                )
            }
        }
    }

    @Test("Without an API key, the server accepts any bearer token or none")
    func acceptsAnyToken() async throws {
        try await withServer(ServiceRegistry(chat: FakeChatService())) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: [.authorization: "Bearer anything"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("With an API key, the server requires the matching bearer token")
    func requiresAPIKey() async throws {
        let configuration = ServerConfiguration(apiKey: "sekret")
        try await withServer(ServiceRegistry(chat: FakeChatService()), configuration: configuration) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.error?.message.hasPrefix("You didn't provide an API key.") == true)
            }
            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: [.authorization: "Bearer wrong"]
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(response.error?.code == "invalid_api_key")
            }
            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: [.authorization: "Bearer sekret"]
            ) { response in
                #expect(response.status == .ok)
            }
            // Authentication runs before routing, as on OpenAI.
            try await client.execute(uri: "/v1/unknown", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("Constant-time comparison matches only equal bytes")
    func constantTimeEquals() {
        typealias Middleware = BearerTokenMiddleware<BasicRequestContext>
        #expect(Middleware.constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
        #expect(!Middleware.constantTimeEquals(Array("abc".utf8), Array("abd".utf8)))
        #expect(!Middleware.constantTimeEquals(Array("abc".utf8), Array("abcd".utf8)))
    }

    @Test("The registry reports unimplemented capabilities as not on the lot")
    func registryAvailability() {
        let registry = ServiceRegistry(chat: FakeChatService())
        #expect(registry.availability(of: .chat) == .available)
        #expect(registry.availability(of: .images) == .unavailable(reason: ServiceRegistry.notImplementedReason))
        #expect(registry.availableCapabilities == [.chat])
    }
}
