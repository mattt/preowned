/// Converts a JSON Schema document to a ``SchemaNode``.
///
/// The parser accepts the subset of JSON Schema
/// that guided generation can enforce:
///
/// - `type` as `string`, `integer`, `number`, `boolean`, `object`, or `array`,
///   or as an array of one of them and `"null"`.
/// - `properties`, `required`, and `additionalProperties: false`.
/// - `items`, `minItems`, and `maxItems`.
/// - `enum` and `const` with string values, and `pattern`.
/// - `minimum`, `maximum`, and, for integers,
///   `exclusiveMinimum` and `exclusiveMaximum`.
/// - `anyOf`, which becomes a choice of schemas,
///   and `oneOf` when its alternatives have different types,
///   so that no value can match two of them,
///   or when a `discriminator` promises that a property tells them apart,
///   as in a Pydantic discriminated union.
/// - `$ref` to `#/$defs/Name` or `#/definitions/Name`.
///
/// The parser ignores annotations such as `title`, `default`, and `format`.
/// It rejects every other keyword with an error
/// that names the keyword and its location,
/// because ignoring a constraint would let the model produce JSON
/// that the client's schema does not allow.
/// For the same reason, it rejects constraints next to `$ref`, `anyOf`, or `oneOf`,
/// and constraints other than `type` next to `enum` or `const`.
///
/// JSON objects have no key order after decoding,
/// so the parser orders properties by their place in `required`,
/// then by name.
public struct JSONSchemaParser: Sendable {
    /// The result of parsing a document.
    public struct Result: Sendable, Equatable {
        public var root: SchemaNode
        public var definitions: [String: SchemaNode]
    }

    /// Keywords that describe a schema without constraining it.
    static let annotations: Set<String> = [
        "title", "description", "default", "examples", "$schema", "$id", "$comment",
        "format", "deprecated", "readOnly", "writeOnly",
    ]

    /// Keywords that the parser converts.
    static let supported: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "minItems",
        "maxItems", "enum", "const", "pattern", "minimum", "maximum", "exclusiveMinimum",
        "exclusiveMaximum", "anyOf", "oneOf", "$ref", "$defs", "definitions", "discriminator",
    ]

    /// The largest integer that a JSON number decoded as `Double` represents exactly.
    static let largestExactInteger = 9_007_199_254_740_991

    /// The `param` value for errors.
    let param: String

    public init(param: String = "response_format") {
        self.param = param
    }

    /// Parses a JSON Schema document.
    public func parse(_ document: JSONValue) throws(OpenAIError) -> Result {
        guard let members = document.objectValue else {
            throw error("The schema must be a JSON object.", at: "#")
        }

        var definitions: [String: SchemaNode] = [:]
        for key in ["$defs", "definitions"] {
            guard let value = members[key] else { continue }
            guard let entries = value.objectValue else {
                throw error("`\(key)` must be an object.", at: "#")
            }
            for (name, schema) in entries {
                let (node, isNullable) = try parseSchema(schema, at: "#/\(key)/\(name)")
                if isNullable {
                    throw error("`null` is supported only in object properties.", at: "#/\(key)/\(name)")
                }
                definitions[name] = node
            }
        }

        let (root, isNullable) = try parseSchema(document, at: "#", isRoot: true)
        if isNullable {
            throw error("The root schema can't allow `null`.", at: "#")
        }

        let result = Result(root: root, definitions: definitions)
        try checkReferences(in: result)
        return result
    }

    // MARK: - Schemas

    /// Parses one schema and reports whether it allows `null`.
    private func parseSchema(
        _ value: JSONValue,
        at path: String,
        isRoot: Bool = false
    ) throws(OpenAIError) -> (SchemaNode, isNullable: Bool) {
        guard let schema = value.objectValue else {
            if value.boolValue != nil {
                throw error("Boolean schemas are not supported.", at: path)
            }
            throw error("A schema must be a JSON object.", at: path)
        }

        for key in schema.keys.sorted()
        where !Self.annotations.contains(key) && !Self.supported.contains(key) {
            throw error("The keyword `\(key)` is not supported.", at: path)
        }
        if !isRoot, schema["$defs"] != nil || schema["definitions"] != nil {
            throw error("Definitions are supported only at the root.", at: path)
        }

        if let reference = schema["$ref"] {
            try checkNoConstraints(besides: "$ref", in: schema, at: path)
            return (try parseReference(reference, at: path), false)
        }

        if let choices = schema["anyOf"] ?? schema["oneOf"] {
            if schema["anyOf"] != nil, schema["oneOf"] != nil {
                throw error("Use `anyOf` or `oneOf`, not both.", at: path)
            }
            let keyword = schema["anyOf"] != nil ? "anyOf" : "oneOf"
            try checkNoConstraints(besides: keyword, in: schema, allowing: ["discriminator"], at: path)
            // A discriminator names a property whose value differs in each alternative,
            // so the alternatives can't overlap; the parser trusts it.
            return try parseChoices(
                choices,
                isExclusive: keyword == "oneOf" && schema["discriminator"] == nil,
                description: schema["description"]?.stringValue,
                at: "\(path)/\(keyword)"
            )
        }

        var (type, isNullable) = try parseType(schema["type"], at: path)

        if let values = schema["enum"] {
            try checkNoConstraints(besides: "enum", in: schema, allowing: ["type"], at: path)
            let (choices, enumIsNullable) = try parseEnum(values, at: path)
            if let type, type != "string" {
                throw error("`enum` is supported only for strings.", at: path)
            }
            // A value must satisfy both keywords, so `null` needs both to allow it.
            let allowsNull = type == nil ? enumIsNullable : isNullable && enumIsNullable
            return (.string(choices: choices, pattern: nil), allowsNull)
        }

        if let constant = schema["const"] {
            try checkNoConstraints(besides: "const", in: schema, allowing: ["type"], at: path)
            guard let string = constant.stringValue else {
                throw error("`const` is supported only for strings.", at: path)
            }
            if let type, type != "string" {
                throw error("`const` is supported only for strings.", at: path)
            }
            return (.string(choices: [string], pattern: nil), false)
        }

        if type == nil, schema["properties"] != nil {
            type = "object"
        }
        guard let type else {
            throw error("A schema must have a `type`.", at: path)
        }

        try checkKeywords(schema, allowedFor: type, at: path)

        switch type {
        case "string":
            return (try parseString(schema, at: path), isNullable)
        case "integer":
            return (try parseInteger(schema, at: path), isNullable)
        case "number":
            return (try parseNumber(schema, at: path), isNullable)
        case "boolean":
            return (.boolean, isNullable)
        case "array":
            return (try parseArray(schema, at: path), isNullable)
        case "object":
            return (try parseObject(schema, at: path), isNullable)
        default:
            throw error("The type `\(type)` is not supported.", at: path)
        }
    }

    /// Throws if `schema` has a constraint that `keyword` would ignore.
    ///
    /// Annotations, root definitions, and the keys in `allowed` may appear next to `keyword`.
    private func checkNoConstraints(
        besides keyword: String,
        in schema: [String: JSONValue],
        allowing allowed: Set<String> = [],
        at path: String
    ) throws(OpenAIError) {
        let ignored: Set<String> = Self.annotations.union(allowed).union([keyword, "$defs", "definitions"])
        for key in schema.keys.sorted() where !ignored.contains(key) {
            throw error("`\(key)` can't be combined with `\(keyword)`.", at: path)
        }
    }

    /// Returns the single non-null type and whether `null` is allowed.
    private func parseType(
        _ value: JSONValue?,
        at path: String
    ) throws(OpenAIError) -> (String?, isNullable: Bool) {
        switch value {
        case nil:
            return (nil, false)
        case .string(let type):
            if type == "null" {
                throw error("A schema can't allow only `null`.", at: path)
            }
            return (type, false)
        case .array(let values):
            var types: [String] = []
            for value in values {
                guard let type = value.stringValue else {
                    throw error("`type` must contain only strings.", at: path)
                }
                types.append(type)
            }
            let isNullable = types.contains("null")
            let others = types.filter { $0 != "null" }
            guard others.count == 1 else {
                throw error("`type` can name one type, optionally with `null`.", at: path)
            }
            return (others[0], isNullable)
        default:
            throw error("`type` must be a string or an array of strings.", at: path)
        }
    }

    private func checkKeywords(
        _ schema: [String: JSONValue],
        allowedFor type: String,
        at path: String
    ) throws(OpenAIError) {
        let specific: [String: Set<String>] = [
            "string": ["pattern"],
            "integer": ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"],
            "number": ["minimum", "maximum"],
            "boolean": [],
            "array": ["items", "minItems", "maxItems"],
            "object": ["properties", "required", "additionalProperties"],
        ]
        let common: Set<String> = ["type", "$defs", "definitions"]
        let allowed = (specific[type] ?? []).union(common).union(Self.annotations)
        for key in schema.keys.sorted() where !allowed.contains(key) {
            throw error("The keyword `\(key)` is not supported for type `\(type)`.", at: path)
        }
    }

    private func parseString(_ schema: [String: JSONValue], at path: String) throws(OpenAIError) -> SchemaNode {
        guard let value = schema["pattern"] else {
            return .string(choices: nil, pattern: nil)
        }
        guard let pattern = value.stringValue else {
            throw error("`pattern` must be a string.", at: path)
        }
        do {
            _ = try Regex(pattern)
        } catch {
            throw self.error("`pattern` is not a valid regular expression.", at: path)
        }
        return .string(choices: nil, pattern: pattern)
    }

    private func parseInteger(_ schema: [String: JSONValue], at path: String) throws(OpenAIError) -> SchemaNode {
        func bound(_ key: String) throws(OpenAIError) -> Int? {
            guard let value = schema[key] else { return nil }
            guard let integer = value.integerValue else {
                throw error("`\(key)` must be an integer.", at: path)
            }
            // JSON numbers decode as `Double`, which is exact only up to 2^53,
            // so a larger bound may have changed in decoding.
            guard integer.magnitude <= Self.largestExactInteger.magnitude else {
                throw error("`\(key)` must be between -(2^53 - 1) and 2^53 - 1.", at: path)
            }
            return integer
        }
        var minimum = try bound("minimum")
        var maximum = try bound("maximum")
        if let exclusive = try bound("exclusiveMinimum") {
            minimum = max(minimum ?? .min, exclusive + 1)
        }
        if let exclusive = try bound("exclusiveMaximum") {
            maximum = min(maximum ?? .max, exclusive - 1)
        }
        if let minimum, let maximum, minimum > maximum {
            throw error("The minimum is greater than the maximum.", at: path)
        }
        return .integer(minimum: minimum, maximum: maximum)
    }

    private func parseNumber(_ schema: [String: JSONValue], at path: String) throws(OpenAIError) -> SchemaNode {
        func bound(_ key: String) throws(OpenAIError) -> Double? {
            guard let value = schema[key] else { return nil }
            guard let number = value.numberValue else {
                throw error("`\(key)` must be a number.", at: path)
            }
            return number
        }
        let minimum = try bound("minimum")
        let maximum = try bound("maximum")
        if let minimum, let maximum, minimum > maximum {
            throw error("The minimum is greater than the maximum.", at: path)
        }
        return .number(minimum: minimum, maximum: maximum)
    }

    private func parseArray(_ schema: [String: JSONValue], at path: String) throws(OpenAIError) -> SchemaNode {
        guard let items = schema["items"] else {
            throw error("An array schema must have `items`.", at: path)
        }
        let (node, isNullable) = try parseSchema(items, at: "\(path)/items")
        if isNullable {
            throw error("`null` is supported only in object properties.", at: "\(path)/items")
        }

        func count(_ key: String) throws(OpenAIError) -> Int? {
            guard let value = schema[key] else { return nil }
            guard let count = value.integerValue, count >= 0 else {
                throw error("`\(key)` must be a non-negative integer.", at: path)
            }
            return count
        }
        let minimum = try count("minItems")
        let maximum = try count("maxItems")
        if let minimum, let maximum, minimum > maximum {
            throw error("`minItems` is greater than `maxItems`.", at: path)
        }
        return .array(items: node, minimumCount: minimum, maximumCount: maximum)
    }

    private func parseObject(_ schema: [String: JSONValue], at path: String) throws(OpenAIError) -> SchemaNode {
        switch schema["additionalProperties"] {
        case nil, .bool(false):
            break
        default:
            throw error("`additionalProperties` must be `false` or absent.", at: path)
        }

        let properties: [String: JSONValue]
        switch schema["properties"] {
        case nil:
            properties = [:]
        case .object(let members):
            properties = members
        default:
            throw error("`properties` must be an object.", at: path)
        }

        var required: [String] = []
        if let value = schema["required"] {
            guard let names = value.arrayValue?.compactMap(\.stringValue),
                names.count == value.arrayValue?.count
            else {
                throw error("`required` must be an array of strings.", at: path)
            }
            for name in names where properties[name] == nil {
                throw error("The required property `\(name)` is not in `properties`.", at: path)
            }
            required = names
        }

        let order =
            required.reduce(into: [String]()) { names, name in
                if !names.contains(name) { names.append(name) }
            } + properties.keys.filter { !required.contains($0) }.sorted()

        var result: [SchemaProperty] = []
        for name in order {
            guard let value = properties[name] else { continue }
            let (node, isNullable) = try parseSchema(value, at: "\(path)/properties/\(name)")
            result.append(
                SchemaProperty(
                    name: name,
                    description: value.objectValue?["description"]?.stringValue,
                    schema: node,
                    isOptional: !required.contains(name) || isNullable,
                    isNullable: isNullable,
                    isRequired: required.contains(name)
                )
            )
        }

        return .object(
            SchemaObject(description: schema["description"]?.stringValue, properties: result)
        )
    }

    private func parseEnum(
        _ value: JSONValue,
        at path: String
    ) throws(OpenAIError) -> ([String], isNullable: Bool) {
        guard let values = value.arrayValue, !values.isEmpty else {
            throw error("`enum` must be a non-empty array.", at: path)
        }
        var choices: [String] = []
        var isNullable = false
        for value in values {
            switch value {
            case .string(let string): choices.append(string)
            case .null: isNullable = true
            default: throw error("`enum` is supported only for strings.", at: path)
            }
        }
        guard !choices.isEmpty else {
            throw error("`enum` must contain at least one string.", at: path)
        }
        return (choices, isNullable)
    }

    private func parseChoices(
        _ value: JSONValue,
        isExclusive: Bool,
        description: String?,
        at path: String
    ) throws(OpenAIError) -> (SchemaNode, isNullable: Bool) {
        guard let values = value.arrayValue, !values.isEmpty else {
            throw error("`anyOf` and `oneOf` must be non-empty arrays.", at: path)
        }
        var nodes: [SchemaNode] = []
        var nullableCount = 0
        for (index, value) in values.enumerated() {
            if let choice = value.objectValue, choice["type"] == .string("null") {
                for key in choice.keys.sorted() where key != "type" && !Self.annotations.contains(key) {
                    throw error("A `null` alternative can't have `\(key)`.", at: "\(path)/\(index)")
                }
                nullableCount += 1
                continue
            }
            let (node, choiceIsNullable) = try parseSchema(value, at: "\(path)/\(index)")
            if choiceIsNullable {
                nullableCount += 1
            }
            nodes.append(node)
        }
        if isExclusive {
            // Guided generation can't stop a value from matching two alternatives,
            // so `oneOf` is supported only when no value can.
            let kinds = nodes.map(Self.kind(of:))
            if nullableCount > 1 || kinds.contains(nil) || Set(kinds).count < kinds.count {
                throw error(
                    "`oneOf` is supported only when its alternatives have different types. "
                        + "Use `anyOf` if a value may match more than one.",
                    at: path
                )
            }
        }
        let isNullable = nullableCount > 0
        switch nodes.count {
        case 0: throw error("A schema can't allow only `null`.", at: path)
        case 1: return (nodes[0], isNullable)
        default: return (.anyOf(nodes, description: description), isNullable)
        }
    }

    /// The JSON type of the values that a node allows, if the node has one type.
    ///
    /// Integers and numbers share a kind, because a value can be both.
    private static func kind(of node: SchemaNode) -> String? {
        switch node {
        case .string: "string"
        case .integer, .number: "number"
        case .boolean: "boolean"
        case .array: "array"
        case .object: "object"
        case .anyOf, .reference: nil
        }
    }

    private func parseReference(_ value: JSONValue, at path: String) throws(OpenAIError) -> SchemaNode {
        guard let reference = value.stringValue else {
            throw error("`$ref` must be a string.", at: path)
        }
        for prefix in ["#/$defs/", "#/definitions/"] where reference.hasPrefix(prefix) {
            let name = String(reference.dropFirst(prefix.count))
            if !name.isEmpty, !name.contains("/") {
                return .reference(name)
            }
        }
        throw error("`$ref` must point to `#/$defs/Name` or `#/definitions/Name`.", at: path)
    }

    // MARK: - References

    private func checkReferences(in result: Result) throws(OpenAIError) {
        func visit(_ node: SchemaNode) throws(OpenAIError) {
            switch node {
            case .reference(let name):
                if result.definitions[name] == nil {
                    throw error("`$ref` names the missing definition `\(name)`.", at: "#")
                }
            case .array(let items, _, _):
                try visit(items)
            case .object(let object):
                for property in object.properties { try visit(property.schema) }
            case .anyOf(let nodes, _):
                for node in nodes { try visit(node) }
            case .string, .integer, .number, .boolean:
                break
            }
        }
        try visit(result.root)
        for (_, node) in result.definitions.sorted(by: { $0.key < $1.key }) {
            try visit(node)
        }
    }

    // MARK: - Errors

    private func error(_ message: String, at path: String) -> OpenAIError {
        .invalidRequest("Invalid JSON Schema at `\(path)`: \(message)", param: param)
    }
}
