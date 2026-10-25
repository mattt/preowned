import FoundationModels

/// Adjusts generated content to the client's JSON Schema
/// where a generation schema can't express it.
///
/// A generation schema has no required property that allows `null`,
/// so ``JSONSchemaParser`` makes such a property optional,
/// and the model can leave it out.
/// Generated content can also include `null`
/// for an optional property whose type doesn't allow it.
/// This adds `null` for a required property that the model left out,
/// removes `null` from a property that doesn't allow it,
/// and keeps the order of the schema's properties.
///
/// For a choice (`anyOf` or `oneOf`), the content conforms to the first alternative
/// that it satisfies, judging by every constraint that ``SchemaNode`` keeps.
/// If it satisfies none, conformance throws instead of returning invalid content.
/// If the content is too large to tell the alternatives apart within the work limit,
/// conformance throws instead of returning content that it couldn't check.
enum GeneratedContentConformance {
    static func conform(
        _ content: GeneratedContent,
        to node: SchemaNode,
        definitions: [String: SchemaNode]
    ) throws(OpenAIError) -> GeneratedContent {
        switch (node, content.kind) {
        case (.object(let object), .structure(var properties, let orderedKeys)):
            for property in object.properties {
                if let value = properties[property.name] {
                    if case .null = value.kind {
                        if !property.isNullable {
                            properties[property.name] = nil
                        }
                    } else {
                        properties[property.name] = try conform(value, to: property.schema, definitions: definitions)
                    }
                } else if property.isRequired && property.isNullable {
                    properties[property.name] = GeneratedContent(kind: .null)
                }
            }
            let schemaKeys = object.properties.map(\.name)
            let keys =
                schemaKeys.filter { properties[$0] != nil }
                + orderedKeys.filter { !schemaKeys.contains($0) && properties[$0] != nil }
            return GeneratedContent(kind: .structure(properties: properties, orderedKeys: keys))

        case (.array(let items, _, _), .array(let elements)):
            var conformed: [GeneratedContent] = []
            for element in elements {
                conformed.append(try conform(element, to: items, definitions: definitions))
            }
            return GeneratedContent(kind: .array(conformed))

        case (.reference(let name), _):
            guard let definition = definitions[name] else { return content }
            return try conform(content, to: definition, definitions: definitions)

        case (.anyOf(let nodes, _), _):
            guard let choice = try alternative(for: content, in: nodes, definitions: definitions) else {
                return content
            }
            return try conform(content, to: choice, definitions: definitions)

        default:
            return content
        }
    }

    /// The alternative to conform `content` to:
    /// the only object or array alternative for an object or an array,
    /// or else the first one whose keys and values, at every level, fit the content.
    private static func alternative(
        for content: GeneratedContent,
        in nodes: [SchemaNode],
        definitions: [String: SchemaNode]
    ) throws(OpenAIError) -> SchemaNode? {
        var visited: Set<String> = []
        let alternatives = flattened(nodes, definitions: definitions, visited: &visited)
        let candidates: [SchemaNode]
        switch content.kind {
        case .structure:
            candidates = alternatives.filter { if case .object = $0 { true } else { false } }
        case .array:
            candidates = alternatives.filter { if case .array = $0 { true } else { false } }
        default:
            return nil
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        // Each candidate gets its own budget,
        // so a costly candidate can't make the others fit by default.
        let valueCount = count(content)
        var matches: [SchemaNode] = []
        var isUncertain = false
        for candidate in candidates {
            var matcher = Matcher(definitions: definitions, valueCount: valueCount)
            if matcher.fits(content, candidate) {
                matches.append(candidate)
                isUncertain = isUncertain || matcher.isExhausted
            }
        }
        if matches.isEmpty {
            throw .server("The structured output doesn't match any alternative in the JSON Schema.")
        }
        if matches.count > 1 && isUncertain {
            throw .server("The structured output was too complex to check against the JSON Schema.")
        }
        // Conforming to any alternative that fits satisfies `anyOf`,
        // and `oneOf` allows only one object or array alternative.
        return matches.first
    }

    /// The alternatives, with references resolved and nested choices expanded.
    ///
    /// Each definition is expanded once,
    /// so definitions that refer to each other repeatedly can't multiply the work.
    static func flattened(
        _ nodes: [SchemaNode],
        definitions: [String: SchemaNode],
        visited: inout Set<String>
    ) -> [SchemaNode] {
        var result: [SchemaNode] = []
        for node in nodes {
            switch node {
            case .reference(let name):
                guard visited.insert(name).inserted, let definition = definitions[name] else { continue }
                result += flattened([definition], definitions: definitions, visited: &visited)
            case .anyOf(let choices, _):
                result += flattened(choices, definitions: definitions, visited: &visited)
            default:
                result.append(node)
            }
        }
        return result
    }

    /// The number of values in `content`, including nested ones.
    private static func count(_ content: GeneratedContent) -> Int {
        switch content.kind {
        case .structure(let properties, _):
            1 + properties.values.reduce(0) { $0 + count($1) }
        case .array(let elements):
            1 + elements.reduce(0) { $0 + count($1) }
        default:
            1
        }
    }

    /// Checks whether content could have come from a schema node.
    private struct Matcher {
        /// The smallest number of checks that one match may make.
        ///
        /// A match may also make ``checksPerValue`` checks for each value in the content.
        /// After that, the matcher treats the rest of the content as fitting
        /// and sets ``isExhausted``,
        /// which bounds the work for recursive or deeply nested schemas.
        static let minimumBudget = 10_000
        static let checksPerValue = 8

        let definitions: [String: SchemaNode]
        private var remaining: Int
        /// Whether the matcher ran out of checks, so a fit may be unchecked.
        private(set) var isExhausted = false
        /// Compiled patterns, or `nil` for a pattern that doesn't compile.
        private var patterns: [String: Regex<AnyRegexOutput>?] = [:]

        init(definitions: [String: SchemaNode], valueCount: Int) {
            self.definitions = definitions
            self.remaining = max(Self.minimumBudget, valueCount * Self.checksPerValue)
        }

        /// Whether `content` satisfies `node` once conformed,
        /// judging by every constraint that ``SchemaNode`` keeps.
        ///
        /// A required property that allows `null` may be missing,
        /// and `null` may stand for an optional property,
        /// because conformance fixes both.
        mutating func fits(_ content: GeneratedContent, _ node: SchemaNode) -> Bool {
            guard remaining > 0 else {
                isExhausted = true
                return true
            }
            guard let node = resolved(node) else { return true }
            remaining -= 1
            switch (content.kind, node) {
            case (_, .anyOf(let nodes, _)):
                // Flattening checks each definition once,
                // however many alternatives refer to it.
                var visited: Set<String> = []
                let alternatives = GeneratedContentConformance.flattened(
                    nodes,
                    definitions: definitions,
                    visited: &visited
                )
                for alternative in alternatives where fits(content, alternative) {
                    return true
                }
                return false
            case (.structure(let properties, let keys), .object(let object)):
                for property in object.properties where !property.isOptional && properties[property.name] == nil {
                    return false
                }
                // Simple values come first, so a value that rules the object out,
                // such as a `const` kind, is checked before nested content uses the budget.
                let simple = keys.filter { properties[$0].map(Self.isSimple) ?? true }
                let nested = keys.filter { !(properties[$0].map(Self.isSimple) ?? true) }
                for key in simple + nested {
                    guard let property = object.properties.first(where: { $0.name == key }),
                        let value = properties[key]
                    else { return false }
                    if case .null = value.kind {
                        if !property.isNullable && !property.isOptional { return false }
                    } else if !fits(value, property.schema) {
                        return false
                    }
                }
                return true
            case (.array(let elements), .array(let items, let minimumCount, let maximumCount)):
                if let minimumCount, elements.count < minimumCount { return false }
                if let maximumCount, elements.count > maximumCount { return false }
                for element in elements where !fits(element, items) {
                    return false
                }
                return true
            case (.string(let value), .string(let choices, let pattern)):
                if let choices, !choices.contains(value) { return false }
                if let pattern { return matches(value, pattern: pattern) }
                return true
            case (.number(let value), .integer(let minimum, let maximum)):
                guard value.rounded() == value else { return false }
                return value >= Double(minimum ?? .min) && value <= Double(maximum ?? .max)
            case (.number(let value), .number(let minimum, let maximum)):
                return value >= (minimum ?? -.infinity) && value <= (maximum ?? .infinity)
            case (.bool, .boolean):
                return true
            default:
                return false
            }
        }

        /// Whether `value` contains a match for `pattern`, as JSON Schema's `pattern` requires.
        ///
        /// A pattern that doesn't compile can't be judged, so it matches.
        private mutating func matches(_ value: String, pattern: String) -> Bool {
            if patterns[pattern] == nil {
                patterns[pattern] = .some(try? Regex(pattern))
            }
            guard case .some(.some(let regex)) = patterns[pattern] else { return true }
            return value.firstMatch(of: regex) != nil
        }

        /// The node at the end of a chain of references,
        /// or `nil` for a missing definition or a cycle, which the matcher can't judge.
        private func resolved(_ node: SchemaNode) -> SchemaNode? {
            var node = node
            var visited: Set<String> = []
            while case .reference(let name) = node {
                guard visited.insert(name).inserted, let definition = definitions[name] else { return nil }
                node = definition
            }
            return node
        }

        /// Whether a value has no nested values.
        private static func isSimple(_ content: GeneratedContent) -> Bool {
            switch content.kind {
            case .structure, .array: false
            default: true
            }
        }
    }
}
