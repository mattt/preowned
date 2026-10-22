import Foundation
import HTTPTypes
import Hummingbird

/// Converts every error to a response with OpenAI's error body.
///
/// Add this middleware before the routes, so that it wraps the other middleware
/// and the not-found responder.
struct OpenAIErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as OpenAIError {
            return error.response()
        } catch let error as HTTPError {
            return Self.openAIError(for: error, request: request).response()
        } catch {
            context.logger.error(
                "Unhandled error",
                metadata: ["error": "\(String(reflecting: error))"]
            )
            return OpenAIError.server().response()
        }
    }

    static func openAIError(for error: HTTPError, request: Request) -> OpenAIError {
        switch error.status {
        case .notFound:
            return .unknownURL(method: request.method.rawValue, path: request.uri.path)
        case .methodNotAllowed:
            return OpenAIError(
                status: .methodNotAllowed,
                message: "Method not allowed (\(request.method.rawValue) \(request.uri.path))",
                type: "invalid_request_error"
            )
        default:
            let message = error.body ?? error.status.reasonPhrase
            return OpenAIError(
                status: error.status,
                message: message,
                type: error.status.code < 500 ? "invalid_request_error" : "server_error"
            )
        }
    }
}

/// Requires `Authorization: Bearer <key>` when the server has an API key.
///
/// Without an API key, the middleware accepts every request,
/// with or without a bearer token.
struct BearerTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let apiKey: String?

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let apiKey else {
            return try await next(request, context)
        }
        guard let authorization = request.headers[.authorization] else {
            throw OpenAIError.missingAPIKey
        }
        let prefix = "Bearer "
        guard authorization.count > prefix.count,
            authorization.prefix(prefix.count).lowercased() == prefix.lowercased()
        else {
            throw OpenAIError.missingAPIKey
        }
        let token = authorization.dropFirst(prefix.count)
        guard Self.constantTimeEquals(Array(token.utf8), Array(apiKey.utf8)) else {
            throw OpenAIError.invalidAPIKey
        }
        return try await next(request, context)
    }

    /// Compares two byte arrays in time that depends only on their lengths.
    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// Rejects requests that a web page in a browser could send to the server.
///
/// Any page that a browser opens can send requests to a server on localhost.
/// Browsers add an `Origin` header to such requests,
/// so the middleware rejects a request whose `Origin`
/// is not in ``ServerConfiguration/allowedOrigins``.
/// A page can also point its own DNS name at 127.0.0.1 (DNS rebinding),
/// so that its requests are not cross-origin;
/// those requests still carry the page's name in `Host`,
/// so the middleware accepts only loopback names and the configured host.
///
/// For an allowed origin,
/// the middleware answers CORS preflight requests
/// and adds CORS headers to every response.
/// It returns its own errors as responses instead of throwing them,
/// so add it before ``OpenAIErrorMiddleware``.
struct LocalRequestMiddleware<Context: RequestContext>: RouterMiddleware {
    let allowedOrigins: Set<String>
    let allowedHostNames: Set<String>
    let port: Int

    init(configuration: ServerConfiguration) {
        self.allowedOrigins = Set(configuration.allowedOrigins.map(Self.normalizedOrigin))
        var host = configuration.host.lowercased()
        if host.contains(":"), !host.hasPrefix("[") {
            host = "[\(host)]"
        }
        self.allowedHostNames = ["127.0.0.1", "localhost", "[::1]", host]
        self.port = configuration.port
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // HTTP/1.1 sends `Host`, which Hummingbird presents as the authority.
        // A request without one cannot come from a browser.
        if let host = request.head.authority ?? request.headers[Self.host], !isAllowed(host: host) {
            return OpenAIError(
                status: .forbidden,
                message: "The Host '\(host)' is not a loopback address or the server's --host.",
                type: "invalid_request_error",
                code: "host_not_allowed"
            )
            .response()
        }

        guard let origin = request.headers[.origin] else {
            return try await next(request, context)
        }
        guard allowedOrigins.contains(Self.normalizedOrigin(origin)) else {
            return OpenAIError(
                status: .forbidden,
                message: "Requests from the origin '\(origin)' are not allowed. "
                    + "Start the server with --allow-origin \(origin) to allow them.",
                type: "invalid_request_error",
                code: "origin_not_allowed"
            )
            .response()
        }

        var response: Response
        if request.method == .options, request.headers[.accessControlRequestMethod] != nil {
            response = Response(status: .noContent)
            response.headers[.accessControlAllowMethods] = "GET, POST, OPTIONS"
            response.headers[.accessControlAllowHeaders] =
                request.headers[.accessControlRequestHeaders] ?? "authorization, content-type"
            response.headers[.accessControlMaxAge] = "600"
        } else {
            response = try await next(request, context)
        }
        response.headers[.accessControlAllowOrigin] = origin
        response.headers[.vary] = "Origin"
        return response
    }

    /// Whether a `Host` value names this server.
    ///
    /// A port, if present, must be the server's port.
    func isAllowed(host: String) -> Bool {
        let value = host.lowercased()
        let name: Substring
        let portText: Substring?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            name = value[...close]
            let rest = value[value.index(after: close)...]
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.hasPrefix(":") else { return false }
                portText = rest.dropFirst()
            }
        } else if let colon = value.lastIndex(of: ":") {
            name = value[..<colon]
            portText = value[value.index(after: colon)...]
        } else {
            name = value[...]
            portText = nil
        }
        if let portText, Int(portText) != port {
            return false
        }
        return allowedHostNames.contains(String(name))
    }

    /// An origin in lowercase without a trailing slash.
    static func normalizedOrigin(_ origin: String) -> String {
        var value = origin.trimmingCharacters(in: .whitespaces).lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static var host: HTTPField.Name { HTTPField.Name("Host")! }
}
