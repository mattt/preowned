import Foundation
import HTTPTypes
import Hummingbird

/// An error that the server reports with OpenAI's error body:
/// `{"error": {"message", "type", "param", "code"}}`.
///
/// Clients parse this shape,
/// so keep the field names and the `type` and `code` values
/// the same as OpenAI's.
public struct OpenAIError: Error, Sendable, Equatable {
    public var status: HTTPResponse.Status
    public var message: String
    public var type: String
    public var param: String?
    public var code: String?
    /// Whether a client should retry the request,
    /// which the response sends as the `x-should-retry` header.
    ///
    /// OpenAI's SDKs retry every 429 and 5xx response twice
    /// unless the header says `false`.
    /// Set `false` for a failure that a retry cannot fix,
    /// such as a capability that this Mac lacks.
    /// `nil` sends no header.
    public var shouldRetry: Bool?

    public init(
        status: HTTPResponse.Status,
        message: String,
        type: String,
        param: String? = nil,
        code: String? = nil,
        shouldRetry: Bool? = nil
    ) {
        self.status = status
        self.message = message
        self.type = type
        self.param = param
        self.code = code
        self.shouldRetry = shouldRetry
    }

    /// The JSON body for this error.
    public var body: ErrorBody {
        ErrorBody(error: .init(message: message, type: type, param: param, code: code))
    }
}

// MARK: - Common errors

extension OpenAIError {
    /// A 400 error for a request that the server cannot accept.
    public static func invalidRequest(
        _ message: String,
        param: String? = nil,
        code: String? = nil
    ) -> OpenAIError {
        OpenAIError(
            status: .badRequest,
            message: message,
            type: "invalid_request_error",
            param: param,
            code: code
        )
    }

    /// A 404 error for a model that the server does not have.
    public static func modelNotFound(_ model: String) -> OpenAIError {
        OpenAIError(
            status: .notFound,
            message: "The model `\(model)` does not exist or you do not have access to it.",
            type: "invalid_request_error",
            param: "model",
            code: "model_not_found"
        )
    }

    /// A 401 error for a request without an API key.
    public static let missingAPIKey = OpenAIError(
        status: .unauthorized,
        message:
            "You didn't provide an API key. "
            + "You need to provide your API key in an Authorization header "
            + "using Bearer auth (i.e. Authorization: Bearer YOUR_KEY).",
        type: "invalid_request_error"
    )

    /// A 401 error for a request with the wrong API key.
    public static let invalidAPIKey = OpenAIError(
        status: .unauthorized,
        message: "Incorrect API key provided.",
        type: "invalid_request_error",
        code: "invalid_api_key"
    )

    /// A 404 error for a path that has no route.
    public static func unknownURL(method: String, path: String) -> OpenAIError {
        OpenAIError(
            status: .notFound,
            message: "Invalid URL (\(method) \(path))",
            type: "invalid_request_error"
        )
    }

    /// A 503 error for a capability that is not available on this Mac.
    ///
    /// A retry gets the same answer,
    /// so the response tells clients not to retry.
    public static func serviceUnavailable(_ message: String) -> OpenAIError {
        OpenAIError(
            status: .serviceUnavailable,
            message: message,
            type: "server_error",
            code: "service_unavailable",
            shouldRetry: false
        )
    }

    /// A 400 error for a request that exceeds the model's context window.
    public static func contextLengthExceeded(_ message: String) -> OpenAIError {
        OpenAIError(
            status: .badRequest,
            message: message,
            type: "invalid_request_error",
            param: "messages",
            code: "context_length_exceeded"
        )
    }

    /// A 400 error for a request or response that a guardrail blocked.
    public static func contentPolicyViolation(_ message: String) -> OpenAIError {
        OpenAIError(
            status: .badRequest,
            message: message,
            type: "invalid_request_error",
            code: "content_policy_violation"
        )
    }

    /// A 429 error for a request that the model's rate limit rejected.
    public static func rateLimited(_ message: String) -> OpenAIError {
        OpenAIError(
            status: .tooManyRequests,
            message: message,
            type: "rate_limit_error",
            code: "rate_limit_exceeded"
        )
    }

    /// A 500 error for an unexpected failure.
    public static func server(
        _ message: String = "The server had an error while processing your request."
    ) -> OpenAIError {
        OpenAIError(status: .internalServerError, message: message, type: "server_error")
    }
}

// MARK: - Body

/// OpenAI's error body.
public struct ErrorBody: Codable, Sendable, Equatable {
    public struct Detail: Codable, Sendable, Equatable {
        public var message: String
        public var type: String
        public var param: String?
        public var code: String?

        public init(message: String, type: String, param: String?, code: String?) {
            self.message = message
            self.type = type
            self.param = param
            self.code = code
        }

        // OpenAI sends `null` for a missing `param` or `code`,
        // so encode `nil` explicitly instead of leaving the key out.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(message, forKey: .message)
            try container.encode(type, forKey: .type)
            try container.encode(param, forKey: .param)
            try container.encode(code, forKey: .code)
        }
    }

    public var error: Detail

    public init(error: Detail) {
        self.error = error
    }
}

// MARK: - Hummingbird

extension OpenAIError: HTTPResponseError {
    public func response(from request: Request, context: some RequestContext) throws -> Response {
        response()
    }

    /// A JSON response with this error's status and body.
    public func response() -> Response {
        let data = (try? JSONCoding.encoder.encode(body)) ?? Data("{}".utf8)
        var headers: HTTPFields = [.contentType: "application/json"]
        if let shouldRetry {
            headers[.shouldRetry] = shouldRetry ? "true" : "false"
        }
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

extension HTTPField.Name {
    /// The header that tells OpenAI's SDKs whether to retry a request.
    public static let shouldRetry = HTTPField.Name("x-should-retry")!
}
