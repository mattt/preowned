import FoundationModels

/// Converts a ``SchemaNode`` to a Foundation Models `GenerationSchema`.
///
/// Objects and choices need unique names in a generation schema.
/// Definitions keep their names,
/// and the builder names other objects after their path,
/// such as `Person_address`.
/// A reference to an object or a choice stays a reference,
/// so recursive definitions work;
/// a reference to any other definition is replaced by the definition.
struct GenerationSchemaBuilder {
    private let definitions: [String: SchemaNode]
    private var usedNames: Set<String>
    /// The unnamed definitions being inlined, to detect cycles.
    private var inlining: Set<String> = []

    private init(definitions: [String: SchemaNode]) {
        self.definitions = definitions
        self.usedNames = Set(definitions.keys)
    }

    /// Builds a generation schema.
    static func schema(
        name: String,
        root: SchemaNode,
        definitions: [String: SchemaNode]
    ) throws -> GenerationSchema {
        var builder = GenerationSchemaBuilder(definitions: definitions)
        let rootName = builder.uniqueName(name.isEmpty ? "Response" : name)
        let rootSchema = try builder.dynamicSchema(for: root, name: rootName)
        var dependencies: [DynamicGenerationSchema] = []
        for (name, node) in definitions.sorted(by: { $0.key < $1.key }) where Self.isNamed(node) {
            dependencies.append(try builder.dynamicSchema(for: node, name: name))
        }
        return try GenerationSchema(root: rootSchema, dependencies: dependencies)
    }

    /// Whether a node has a name in a generation schema.
    private static func isNamed(_ node: SchemaNode) -> Bool {
        switch node {
        case .object, .anyOf: true
        case .string(let choices, _): choices != nil
        default: false
        }
    }

    private mutating func uniqueName(_ base: String) -> String {
        var name = base
        var suffix = 2
        while usedNames.contains(name) {
            name = "\(base)\(suffix)"
            suffix += 1
        }
        usedNames.insert(name)
        return name
    }

    private mutating func dynamicSchema(
        for node: SchemaNode,
        name: String
    ) throws -> DynamicGenerationSchema {
        switch node {
        case .string(let choices?, _):
            return DynamicGenerationSchema(name: name, anyOf: choices)

        case .string(nil, let pattern?):
            let regex = try Regex(pattern)
            return DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])

        case .string(nil, nil):
            return DynamicGenerationSchema(type: String.self)

        case .integer(let minimum, let maximum):
            var guides: [GenerationGuide<Int>] = []
            switch (minimum, maximum) {
            case (let minimum?, let maximum?): guides.append(.range(minimum...maximum))
            case (let minimum?, nil): guides.append(.minimum(minimum))
            case (nil, let maximum?): guides.append(.maximum(maximum))
            case (nil, nil): break
            }
            return DynamicGenerationSchema(type: Int.self, guides: guides)

        case .number(let minimum, let maximum):
            var guides: [GenerationGuide<Double>] = []
            switch (minimum, maximum) {
            case (let minimum?, let maximum?): guides.append(.range(minimum...maximum))
            case (let minimum?, nil): guides.append(.minimum(minimum))
            case (nil, let maximum?): guides.append(.maximum(maximum))
            case (nil, nil): break
            }
            return DynamicGenerationSchema(type: Double.self, guides: guides)

        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)

        case .array(let items, let minimumCount, let maximumCount):
            let itemSchema = try nestedSchema(for: items, name: "\(name)_item")
            return DynamicGenerationSchema(
                arrayOf: itemSchema,
                minimumElements: minimumCount,
                maximumElements: maximumCount
            )

        case .object(let object):
            var properties: [DynamicGenerationSchema.Property] = []
            for property in object.properties {
                let schema = try nestedSchema(for: property.schema, name: "\(name)_\(property.name)")
                properties.append(
                    DynamicGenerationSchema.Property(
                        name: property.name,
                        description: property.description,
                        schema: schema,
                        isOptional: property.isOptional
                    )
                )
            }
            if object.representsNilExplicitly, #available(macOS 26.4, *) {
                return DynamicGenerationSchema(
                    name: name,
                    description: object.description,
                    representNilExplicitlyInGeneratedContent: true,
                    properties: properties
                )
            }
            return DynamicGenerationSchema(
                name: name,
                description: object.description,
                properties: properties
            )

        case .anyOf(let nodes, let description):
            var choices: [DynamicGenerationSchema] = []
            for (index, node) in nodes.enumerated() {
                choices.append(try nestedSchema(for: node, name: "\(name)_\(index + 1)"))
            }
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)

        case .reference(let reference):
            guard let definition = definitions[reference] else {
                throw OpenAIError.invalidRequest(
                    "Invalid JSON Schema: `$ref` names the missing definition `\(reference)`.",
                    param: "response_format"
                )
            }
            if Self.isNamed(definition) {
                return DynamicGenerationSchema(referenceTo: reference)
            }
            // Only objects and choices can refer to themselves,
            // because only they have names in a generation schema.
            guard inlining.insert(reference).inserted else {
                throw OpenAIError.invalidRequest(
                    "Invalid JSON Schema: the definition `\(reference)` refers to itself "
                        + "without an object or a choice in between.",
                    param: "response_format"
                )
            }
            defer { inlining.remove(reference) }
            return try dynamicSchema(for: definition, name: reference)
        }
    }

    /// Builds the schema of a property, an array item, or a choice,
    /// with a unique name if the schema needs one.
    private mutating func nestedSchema(
        for node: SchemaNode,
        name: String
    ) throws -> DynamicGenerationSchema {
        if Self.isNamed(node) {
            return try dynamicSchema(for: node, name: uniqueName(name))
        }
        return try dynamicSchema(for: node, name: name)
    }
}
