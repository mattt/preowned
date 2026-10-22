/// A JSON Schema, reduced to the subset that guided generation supports.
///
/// ``JSONSchemaParser`` produces a node from a JSON Schema document,
/// and the Foundation Models chat service converts the node
/// to a `DynamicGenerationSchema`.
/// The node keeps the conversion testable without Apple Intelligence.
public indirect enum SchemaNode: Sendable, Equatable {
    /// A string, limited to `choices` or to `pattern` when either is set.
    case string(choices: [String]?, pattern: String?)
    case integer(minimum: Int?, maximum: Int?)
    case number(minimum: Double?, maximum: Double?)
    case boolean
    case array(items: SchemaNode, minimumCount: Int?, maximumCount: Int?)
    case object(SchemaObject)
    /// A value that matches one of several schemas.
    case anyOf([SchemaNode], description: String?)
    /// A reference to a definition in `$defs` or `definitions`.
    case reference(String)
}

/// An object schema with ordered properties.
public struct SchemaObject: Sendable, Equatable {
    public var description: String?
    public var properties: [SchemaProperty]

    public init(description: String? = nil, properties: [SchemaProperty]) {
        self.description = description
        self.properties = properties
    }

    /// Whether any property allows `null`,
    /// in which case generated content includes absent values as `null`.
    public var representsNilExplicitly: Bool {
        properties.contains(where: \.isNullable)
    }
}

/// A property of an object schema.
public struct SchemaProperty: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var schema: SchemaNode
    /// Whether the property is absent from `required`.
    public var isOptional: Bool
    /// Whether the property's type includes `null`.
    public var isNullable: Bool

    public init(
        name: String,
        description: String? = nil,
        schema: SchemaNode,
        isOptional: Bool = false,
        isNullable: Bool = false
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.isOptional = isOptional
        self.isNullable = isNullable
    }
}
