import Hummingbird

/// `GET /v1/models` and `GET /v1/models/{id}`.
///
/// Both list only the capabilities that are available now,
/// so a client sees the models that it can use.
struct ModelRoutes {
    let services: ServiceRegistry

    func register(on router: Router<BasicRequestContext>) {
        router.get("/v1/models") { _, _ in
            try Response.json(ModelList(data: availableModels()))
        }

        router.get("/v1/models/:id") { _, context in
            let id = try context.parameters.require("id")
            guard let model = availableModels().first(where: { $0.id == id }) else {
                throw OpenAIError.modelNotFound(id)
            }
            return try Response.json(model)
        }
    }

    private func availableModels() -> [ModelObject] {
        services.availableCapabilities.map { ModelObject(id: $0.modelID) }
    }
}
