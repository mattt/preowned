import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PreownedKit

@Suite("Embeddings")
struct EmbeddingRoutesTests {
    let services = ServiceRegistry(embeddings: FakeEmbeddingService())

    @Test("A string input returns one vector, the canonical model, and usage")
    func stringInput() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/embeddings",
                json: #"{"model": "text-embedding-3-small", "input": "hello"}"#
            ) { response in
                #expect(response.status == .ok)
                let body = try response.decode(EmbeddingResponse.self)
                #expect(body.object == "list")
                #expect(body.model == "apple-nl-embedding")
                #expect(body.data.count == 1)
                #expect(body.data[0].object == "embedding")
                #expect(body.data[0].index == 0)
                #expect(body.data[0].embedding == .float([5, 0.5, -1]))
                #expect(body.usage == EmbeddingUsage(promptTokens: 5))
                #expect(response.text.contains(#""prompt_tokens":5"#))
                #expect(response.text.contains(#""total_tokens":5"#))
            }
        }
    }

    @Test("An array input returns vectors in order")
    func arrayInput() async throws {
        try await withServer(services) { client in
            try await client.post("/v1/embeddings", json: #"{"input": ["a", "bcd", "ef"]}"#) { response in
                let body = try response.decode(EmbeddingResponse.self)
                #expect(body.data.map(\.index) == [0, 1, 2])
                #expect(body.data.map { $0.embedding.values?.first } == [1, 3, 2])
                #expect(body.usage.promptTokens == 6)
            }
        }
    }

    @Test("Base64 encoding gives little-endian 32-bit floats")
    func base64() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/embeddings",
                json: #"{"input": "hello", "encoding_format": "base64"}"#
            ) { response in
                let body = try response.decode(EmbeddingResponse.self)
                guard case .base64(let string) = body.data[0].embedding else {
                    Issue.record("Expected a base64 string")
                    return
                }
                let data = try #require(Data(base64Encoded: string))
                #expect(data == Data([0, 0, 0xA0, 0x40, 0, 0, 0, 0x3F, 0, 0, 0x80, 0xBF]))
                #expect(body.data[0].embedding.values == [5, 0.5, -1])
            }
        }
    }

    @Test("dimensions equal to the native size is accepted")
    func nativeDimensions() async throws {
        try await withServer(services) { client in
            try await client.post("/v1/embeddings", json: #"{"input": "a", "dimensions": 3}"#) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test(
        "Invalid requests return 400 with the parameter",
        arguments: [
            (#"{"input": [1, 2, 3]}"#, "input"),
            (#"{"input": [[1, 2], [3]]}"#, "input"),
            (#"{"input": []}"#, "input"),
            (#"{"input": ""}"#, "input"),
            (#"{"input": ["a", ""]}"#, "input"),
            (#"{"input": "a", "encoding_format": "hex"}"#, "encoding_format"),
            (#"{"input": "a", "dimensions": 256}"#, "dimensions"),
        ]
    )
    func invalidRequests(json: String, param: String) async throws {
        try await withServer(services) { client in
            try await client.post("/v1/embeddings", json: json) { response in
                #expect(response.status == .badRequest)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                #expect(error.param == param)
            }
        }
    }

    @Test("Too many inputs return 400")
    func tooManyInputs() async throws {
        let inputs = Array(repeating: "\"a\"", count: 2049).joined(separator: ",")
        try await withServer(services) { client in
            try await client.post("/v1/embeddings", json: #"{"input": [\#(inputs)]}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.param == "input")
            }
        }
    }

    @Test("A missing or mistyped input returns 400")
    func missingInput() async throws {
        try await withServer(services) { client in
            try await client.post("/v1/embeddings", json: #"{"model": "x"}"#) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.message == "Missing required parameter: 'input'.")
            }
            try await client.post("/v1/embeddings", json: #"{"input": {"text": "a"}}"#) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("An unavailable service returns 503 server_error")
    func unavailable() async throws {
        let services = ServiceRegistry(
            embeddings: FakeEmbeddingService(availability: .unavailable(reason: "No model."))
        )
        try await withServer(services) { client in
            try await client.post("/v1/embeddings", json: #"{"input": "a"}"#) { response in
                #expect(response.status == .serviceUnavailable)
                let error = try #require(response.error)
                #expect(error.type == "server_error")
                #expect(error.code == "service_unavailable")
                #expect(error.message == "No model.")
            }
        }
        try await withServer(ServiceRegistry()) { client in
            try await client.post("/v1/embeddings", json: #"{"input": "a"}"#) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
    }

    @Test("Strict mode rejects other model names, and the chat model is a mistake")
    func models() async throws {
        let configuration = ServerConfiguration(strictModels: true)
        try await withServer(services, configuration: configuration) { client in
            try await client.post(
                "/v1/embeddings",
                json: #"{"model": "text-embedding-3-small", "input": "a"}"#
            ) { response in
                #expect(response.status == .notFound)
                #expect(response.error?.code == "model_not_found")
            }
            try await client.post(
                "/v1/embeddings",
                json: #"{"model": "apple-nl-embedding", "input": "a"}"#
            ) { response in
                #expect(response.status == .ok)
            }
        }
        try await withServer(services) { client in
            try await client.post(
                "/v1/embeddings",
                json: #"{"model": "apple-foundation-model", "input": "a"}"#
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.error?.code == "model_not_supported")
            }
        }
    }
}
