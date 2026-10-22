import Hummingbird

/// Converts every error to a response with OpenAI's error body.
///
/// Add this middleware first, so that it wraps the other middleware
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
