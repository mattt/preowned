/// Maps the model name in a request to a canonical model ID.
///
/// By default, a request can name any model, such as `gpt-4o`,
/// and the response reports the canonical ID,
/// so that existing client code works without changes.
/// In strict mode, a request must name the canonical ID.
///
/// In both modes, a request that names the canonical ID of another capability fails,
/// because that request is a mistake rather than a name from existing code.
public struct ModelResolver: Sendable {
    public var isStrict: Bool

    public init(isStrict: Bool = false) {
        self.isStrict = isStrict
    }

    /// Returns the canonical model ID for a request to a capability.
    public func resolve(
        _ requested: String?,
        for capability: Capability
    ) throws(OpenAIError) -> String {
        guard let requested, !requested.isEmpty else {
            if isStrict {
                throw .invalidRequest(
                    "You must provide a model parameter.",
                    param: "model",
                    code: "missing_required_parameter"
                )
            }
            return capability.modelID
        }

        if requested == capability.modelID {
            return requested
        }

        if let other = Capability(modelID: requested) {
            throw .invalidRequest(
                "The model `\(requested)` is for \(other.displayName.lowercased()), "
                    + "not \(capability.displayName.lowercased()). Use `\(capability.modelID)`.",
                param: "model",
                code: "model_not_supported"
            )
        }

        if isStrict {
            throw .modelNotFound(requested)
        }
        return capability.modelID
    }
}
