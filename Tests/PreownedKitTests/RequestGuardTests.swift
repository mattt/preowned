import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import PreownedKit

@Suite("Origin, Host, and Content-Type checks")
struct RequestGuardTests {
    let services = ServiceRegistry(chat: FakeChatService(), images: FakeImageService())

    @Test("A request from a browser origin returns 403 by default")
    func foreignOrigin() async throws {
        try await withServer(services) { client in
            try await client.post(
                "/v1/chat/completions",
                json: chatBody(),
                headers: [.origin: "https://example.com"]
            ) { response in
                #expect(response.status == .forbidden)
                let error = try #require(response.error)
                #expect(error.type == "invalid_request_error")
                #expect(error.code == "origin_not_allowed")
                #expect(error.message.contains("--allow-origin"))
            }
            try await client.execute(
                uri: "/v1/models",
                method: .get,
                headers: [.origin: "null"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test("An allowed origin gets a response with CORS headers")
    func allowedOrigin() async throws {
        let configuration = ServerConfiguration(allowedOrigins: ["http://localhost:5173/"])
        try await withServer(services, configuration: configuration) { client in
            try await client.post(
                "/v1/chat/completions",
                json: chatBody(),
                headers: [.origin: "http://LOCALHOST:5173"]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.accessControlAllowOrigin] == "http://LOCALHOST:5173")
                #expect(response.headers[.vary] == "Origin")
            }
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .options,
                headers: [
                    .origin: "http://localhost:5173",
                    .accessControlRequestMethod: "POST",
                    .accessControlRequestHeaders: "authorization, content-type",
                ]
            ) { response in
                #expect(response.status == .noContent)
                #expect(response.headers[.accessControlAllowOrigin] == "http://localhost:5173")
                #expect(response.headers[.accessControlAllowHeaders] == "authorization, content-type")
                #expect(response.headers[.accessControlAllowMethods]?.contains("POST") == true)
            }
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .options,
                headers: [.origin: "https://example.com", .accessControlRequestMethod: "POST"]
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }

    @Test(
        "Only loopback names and the configured host pass the Host check",
        arguments: [
            ("127.0.0.1", true),
            ("127.0.0.1:8027", true),
            ("localhost", true),
            ("LOCALHOST:8027", true),
            ("[::1]:8027", true),
            ("[::1]", true),
            ("studio.local:8027", true),
            ("localhost:9999", false),
            ("evil.example", false),
            ("evil.example:8027", false),
            ("127.0.0.1.evil.example", false),
            ("", false),
        ]
    )
    func hosts(host: String, isAllowed: Bool) {
        let guardrail = LocalRequestMiddleware<BasicRequestContext>(
            configuration: ServerConfiguration(host: "studio.local", port: 8027)
        )
        #expect(guardrail.isAllowed(host: host) == isAllowed)
    }

    @Test("A JSON route rejects a body without a JSON Content-Type")
    func jsonContentType() async throws {
        try await withServer(services) { client in
            for contentType in ["text/plain", "application/x-www-form-urlencoded"] {
                try await client.execute(
                    uri: "/v1/chat/completions",
                    method: .post,
                    headers: [.contentType: contentType],
                    body: ByteBuffer(string: chatBody())
                ) { response in
                    #expect(response.status == .unsupportedMediaType)
                    #expect(response.error?.type == "invalid_request_error")
                    #expect(response.error?.message.contains("application/json") == true)
                }
            }
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: ByteBuffer(string: chatBody())
            ) { response in
                #expect(response.status == .unsupportedMediaType)
            }
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                headers: [.contentType: "Application/JSON; charset=utf-8"],
                body: ByteBuffer(string: chatBody())
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
