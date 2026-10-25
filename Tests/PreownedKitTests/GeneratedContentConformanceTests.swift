import Foundation
import FoundationModels
import Testing

@testable import PreownedKit

@Suite("Generated content conformance")
struct GeneratedContentConformanceTests {
    private func conform(_ json: String, schema: String) throws -> GeneratedContent {
        let parsed = try JSONSchemaParser().parse(JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8)))
        return try GeneratedContentConformance.conform(
            try GeneratedContent(json: json),
            to: parsed.root,
            definitions: parsed.definitions
        )
    }

    private func keys(of content: GeneratedContent) -> [String]? {
        guard case .structure(_, let orderedKeys) = content.kind else { return nil }
        return orderedKeys
    }

    private func value(_ key: String, in content: GeneratedContent) -> GeneratedContent.Kind? {
        guard case .structure(let properties, _) = content.kind else { return nil }
        return properties[key]?.kind
    }

    private let schema = #"""
        {
          "type": "object",
          "properties": {
            "name": {"type": "string"},
            "note": {"type": ["string", "null"]},
            "nickname": {"type": "string"}
          },
          "required": ["name", "note"]
        }
        """#

    @Test("A required nullable property that the model left out becomes null, in schema order")
    func addsNull() throws {
        let content = try conform(#"{"name": "Ada"}"#, schema: schema)
        #expect(keys(of: content) == ["name", "note"])
        #expect(value("note", in: content) == .null)
    }

    @Test("Null is removed from a property whose type doesn't allow it")
    func removesNull() throws {
        let content = try conform(#"{"name": "Ada", "note": null, "nickname": null}"#, schema: schema)
        #expect(keys(of: content) == ["name", "note"])
        #expect(value("note", in: content) == .null)
        #expect(value("nickname", in: content) == nil)
    }

    @Test("Content that already conforms keeps its values, in schema order")
    func unchanged() throws {
        let json = #"{"nickname": "A", "note": "Hi", "name": "Ada"}"#
        let content = try conform(json, schema: schema)
        #expect(keys(of: content) == ["name", "note", "nickname"])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(content.jsonString.utf8))
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(decoded == expected)
    }

    @Test("Objects in arrays and definitions conform too")
    func nested() throws {
        let content = try conform(
            #"{"people": [{"name": "Ada"}, {"name": "Grace", "note": "Hi"}]}"#,
            schema: ##"""
                {
                  "type": "object",
                  "properties": {"people": {"type": "array", "items": {"$ref": "#/$defs/Person"}}},
                  "required": ["people"],
                  "$defs": {
                    "Person": {
                      "type": "object",
                      "properties": {"name": {"type": "string"}, "note": {"type": ["string", "null"]}},
                      "required": ["name", "note"]
                    }
                  }
                }
                """##
        )
        guard case .array(let people)? = value("people", in: content), people.count == 2 else {
            Issue.record("The people array is missing.")
            return
        }
        #expect(value("note", in: people[0]) == .null)
        #expect(value("note", in: people[1]) == .string("Hi"))
    }

    @Test("An object inside a choice conforms to the alternative that produced it")
    func choices() throws {
        let schema = ##"""
            {
              "type": "object",
              "properties": {
                "choice": {"anyOf": [{"$ref": "#/$defs/Address"}, {"type": "string"}, {"type": "null"}]},
                "contact": {
                  "anyOf": [
                    {"type": "object", "properties": {"email": {"type": ["string", "null"]}}, "required": ["email"]},
                    {
                      "type": "object",
                      "properties": {"phone": {"type": "string"}, "ext": {"type": ["string", "null"]}},
                      "required": ["phone", "ext"]
                    }
                  ]
                },
                "lines": {"anyOf": [{"type": "array", "items": {"$ref": "#/$defs/Address"}}, {"type": "string"}]}
              },
              "required": ["choice", "contact", "lines"],
              "$defs": {
                "Address": {
                  "type": "object",
                  "properties": {"street": {"type": "string"}, "note": {"type": ["string", "null"]}},
                  "required": ["street", "note"]
                }
              }
            }
            """##
        let content = try conform(
            #"{"choice": {"street": "Main"}, "contact": {"phone": "555"}, "lines": [{"street": "Elm"}]}"#,
            schema: schema
        )
        guard let choice = object("choice", in: content),
            let contact = object("contact", in: content),
            case .array(let lines)? = value("lines", in: content)
        else {
            Issue.record("A property is missing.")
            return
        }
        #expect(value("note", in: choice) == .null)
        #expect(value("ext", in: contact) == .null)
        #expect(value("email", in: contact) == nil)
        #expect(lines.count == 1 && value("note", in: lines[0]) == .null)

        let text = try conform(#"{"choice": "Main", "contact": {"email": null}, "lines": "none"}"#, schema: schema)
        #expect(value("choice", in: text) == .string("Main"))
        #expect(value("lines", in: text) == .string("none"))
    }

    @Test("Alternatives with the same keys are told apart by their values")
    func sameKeys() throws {
        let schema = ##"""
            {
              "type": "object",
              "properties": {
                "pet": {"anyOf": [{"$ref": "#/$defs/Cat"}, {"$ref": "#/$defs/Dog"}]},
                "tags": {
                  "anyOf": [
                    {"type": "array", "items": {"type": "string"}},
                    {"type": "array", "items": {"$ref": "#/$defs/Cat"}}
                  ]
                }
              },
              "required": ["pet", "tags"],
              "$defs": {
                "Cat": {
                  "type": "object",
                  "properties": {"kind": {"const": "cat"}, "note": {"type": ["string", "null"]}},
                  "required": ["kind", "note"]
                },
                "Dog": {
                  "type": "object",
                  "properties": {"kind": {"const": "dog"}, "note": {"type": ["string", "null"]}, "breed": {"type": "string"}},
                  "required": ["kind", "note", "breed"]
                }
              }
            }
            """##
        let cat = try conform(#"{"pet": {"kind": "cat"}, "tags": [{"kind": "cat"}]}"#, schema: schema)
        guard let pet = object("pet", in: cat), case .array(let tags)? = value("tags", in: cat) else {
            Issue.record("A property is missing.")
            return
        }
        #expect(keys(of: pet) == ["kind", "note"])
        #expect(value("note", in: pet) == .null)
        #expect(tags.count == 1 && value("note", in: tags[0]) == .null)

        let dog = try conform(#"{"pet": {"kind": "dog", "breed": "beagle"}, "tags": ["good"]}"#, schema: schema)
        #expect(object("pet", in: dog).flatMap { keys(of: $0) } == ["kind", "note", "breed"])
    }

    @Test("Definitions that share alternatives expand once")
    func sharedReferences() throws {
        var definitions: [String: SchemaNode] = [
            "Leaf": .object(SchemaObject(properties: [SchemaProperty(name: "note", schema: .boolean)]))
        ]
        var previous = "Leaf"
        for index in 0..<30 {
            definitions["Choice\(index)"] = .anyOf([.reference(previous), .reference(previous)], description: nil)
            previous = "Choice\(index)"
        }
        var visited: Set<String> = []
        let alternatives = GeneratedContentConformance.flattened(
            [.reference(previous)],
            definitions: definitions,
            visited: &visited
        )
        #expect(alternatives.count == 1)
    }

    @Test("Array alternatives are told apart by their referenced items, and recursive schemas terminate")
    func referencedItems() throws {
        let pets = try conform(
            #"{"pets": [{"kind": "cat"}]}"#,
            schema: ##"""
                {
                  "type": "object",
                  "properties": {
                    "pets": {
                      "anyOf": [
                        {"type": "array", "items": {"$ref": "#/$defs/Cat"}},
                        {"type": "array", "items": {"$ref": "#/$defs/Dog"}}
                      ]
                    }
                  },
                  "required": ["pets"],
                  "$defs": {
                    "Cat": {
                      "type": "object",
                      "properties": {"kind": {"const": "cat"}, "note": {"type": ["string", "null"]}},
                      "required": ["kind", "note"]
                    },
                    "Dog": {
                      "type": "object",
                      "properties": {"kind": {"const": "dog"}, "note": {"type": ["string", "null"]}},
                      "required": ["kind", "note"]
                    }
                  }
                }
                """##
        )
        guard case .array(let elements)? = value("pets", in: pets), elements.count == 1 else {
            Issue.record("The pets array is missing.")
            return
        }
        #expect(value("note", in: elements[0]) == .null)

        let tree = try conform(
            #"{"root": {"name": "a", "child": {"name": "b", "child": {"name": "c"}}}}"#,
            schema: ##"""
                {
                  "type": "object",
                  "properties": {"root": {"anyOf": [{"$ref": "#/$defs/Node"}, {"type": "string"}]}},
                  "required": ["root"],
                  "$defs": {
                    "Node": {
                      "type": "object",
                      "properties": {
                        "name": {"type": "string"},
                        "child": {"anyOf": [{"$ref": "#/$defs/Node"}, {"type": "null"}]}
                      },
                      "required": ["name", "child"]
                    }
                  }
                }
                """##
        )
        let leaf = object("root", in: tree).flatMap { object("child", in: $0) }.flatMap { object("child", in: $0) }
        #expect(leaf.flatMap { value("child", in: $0) } == .null)
    }

    @Test("A costly alternative doesn't stop another from matching")
    func costlyAlternative() throws {
        var definitions: [String: SchemaNode] = ["Leaf": .boolean]
        var previous = "Leaf"
        for index in 0..<30 {
            definitions["Choice\(index)"] = .anyOf([.reference(previous), .reference(previous)], description: nil)
            previous = "Choice\(index)"
        }
        let costly = SchemaNode.object(
            SchemaObject(properties: [SchemaProperty(name: "kind", schema: .reference(previous))]))
        let cat = SchemaNode.object(
            SchemaObject(properties: [
                SchemaProperty(name: "kind", schema: .string(choices: ["cat"], pattern: nil)),
                SchemaProperty(
                    name: "note",
                    schema: .string(choices: nil, pattern: nil),
                    isOptional: true,
                    isNullable: true,
                    isRequired: true
                ),
            ])
        )
        for alternatives in [[costly, cat], [cat, costly]] {
            let content = try GeneratedContentConformance.conform(
                try GeneratedContent(json: #"{"kind": "cat"}"#),
                to: .anyOf(alternatives, description: nil),
                definitions: definitions
            )
            #expect(value("note", in: content) == .null)
        }
    }

    @Test("A long array and aliased references don't hide the value that picks an alternative")
    func longContent() throws {
        var definitions: [String: SchemaNode] = ["Text": .string(choices: nil, pattern: nil)]
        var previous = "Text"
        for index in 0..<12 {
            definitions["Alias\(index)"] = .reference(previous)
            previous = "Alias\(index)"
        }
        func pet(_ kind: String) -> SchemaNode {
            .object(
                SchemaObject(properties: [
                    SchemaProperty(
                        name: "data",
                        schema: .array(items: .reference(previous), minimumCount: nil, maximumCount: nil)
                    ),
                    SchemaProperty(name: "kind", schema: .string(choices: [kind], pattern: nil)),
                    SchemaProperty(
                        name: "note",
                        schema: .string(choices: nil, pattern: nil),
                        isOptional: true,
                        isNullable: true,
                        isRequired: true
                    ),
                ])
            )
        }
        let data = (0..<20_000).map { _ in GeneratedContent(kind: .string("")) }
        let content = try GeneratedContentConformance.conform(
            GeneratedContent(
                kind: .structure(
                    properties: [
                        "data": GeneratedContent(kind: .array(data)), "kind": GeneratedContent(kind: .string("cat")),
                    ],
                    orderedKeys: ["data", "kind"]
                )
            ),
            to: .anyOf([pet("dog"), pet("cat")], description: nil),
            definitions: definitions
        )
        #expect(value("note", in: content) == .null)
    }

    @Test("Content too large to tell alternatives apart is an error, not unchecked output")
    func exhausted() throws {
        // Both lists accept the same 40 tags and differ only in one more,
        // so only the last element, after the work limit, tells them apart.
        func list(lastTag: String) -> SchemaNode {
            let tags = (0..<40).map { "t\($0)" } + [lastTag]
            let items = SchemaNode.anyOf(
                tags.map { tag in
                    .object(
                        SchemaObject(properties: [
                            SchemaProperty(name: "tag", schema: .string(choices: [tag], pattern: nil))
                        ]))
                },
                description: nil
            )
            return .object(
                SchemaObject(properties: [
                    SchemaProperty(name: "items", schema: .array(items: items, minimumCount: nil, maximumCount: nil))
                ])
            )
        }
        func element(_ tag: String) -> GeneratedContent {
            GeneratedContent(
                kind: .structure(properties: ["tag": GeneratedContent(kind: .string(tag))], orderedKeys: ["tag"]))
        }
        let elements = Array(repeating: element("t39"), count: 3_000) + [element("x")]
        let content = GeneratedContent(
            kind: .structure(properties: ["items": GeneratedContent(kind: .array(elements))], orderedKeys: ["items"])
        )
        let error = #expect(throws: OpenAIError.self) {
            try GeneratedContentConformance.conform(
                content,
                to: .anyOf([list(lastTag: "x"), list(lastTag: "y")], description: nil),
                definitions: [:]
            )
        }
        #expect(error?.status == .internalServerError)
    }

    @Test("Content that fits several alternatives conforms to the first")
    func severalFit() throws {
        let content = try conform(
            #"{"value": {}}"#,
            schema: #"""
                {
                  "type": "object",
                  "properties": {
                    "value": {
                      "anyOf": [
                        {"type": "object", "properties": {"name": {"type": ["string", "null"]}}, "required": ["name"]},
                        {"type": "object", "properties": {"id": {"type": ["string", "null"]}}, "required": ["id"]}
                      ]
                    }
                  },
                  "required": ["value"]
                }
                """#
        )
        let value = object("value", in: content)
        #expect(value.flatMap { keys(of: $0) } == ["name"])
        #expect(value.flatMap { self.value("name", in: $0) } == .null)
    }

    @Test(
        "An alternative whose constraints the content breaks isn't chosen",
        arguments: [
            (
                #"{"shared": "x"}"#,
                #"{"shared": {"type": "string"}, "must": {"type": "string"}}"#,
                #"["shared", "must", "note"]"#,
                #"{"shared": {"type": "string"}}"#
            ),
            (
                #"{"id": 0}"#,
                #"{"id": {"type": "integer", "minimum": 100}}"#,
                #"["id", "note"]"#,
                #"{"id": {"type": "integer", "maximum": 1}}"#
            ),
            (
                #"{"name": "bob"}"#,
                #"{"name": {"type": "string", "pattern": "^A"}}"#,
                #"["name", "note"]"#,
                #"{"name": {"type": "string", "pattern": "^b"}}"#
            ),
            (
                #"{"tags": []}"#,
                #"{"tags": {"type": "array", "items": {"type": "string"}, "minItems": 1}}"#,
                #"["tags", "note"]"#,
                #"{"tags": {"type": "array", "items": {"type": "string"}, "maxItems": 0}}"#
            ),
        ]
    )
    func constraints(json: String, firstProperties: String, firstRequired: String, secondProperties: String) throws {
        // The first alternative also has a required nullable `note`,
        // which conformance would add if it chose the first alternative.
        let first = firstProperties.dropLast() + #", "note": {"type": ["string", "null"]}}"#
        let schema = """
            {
              "anyOf": [
                {"type": "object", "properties": \(first), "required": \(firstRequired)},
                {"type": "object", "properties": \(secondProperties), "required": []}
              ]
            }
            """
        let content = try conform(json, schema: schema)
        #expect(value("note", in: content) == nil)
    }

    @Test("Content that satisfies no alternative is an error")
    func noAlternative() throws {
        let error = #expect(throws: OpenAIError.self) {
            try conform(
                #"{"id": 5}"#,
                schema: #"""
                    {
                      "anyOf": [
                        {"type": "object", "properties": {"id": {"type": "integer", "maximum": 1}}, "required": ["id"]},
                        {"type": "object", "properties": {"id": {"type": "integer", "minimum": 10}}, "required": ["id"]}
                      ]
                    }
                    """#
            )
        }
        #expect(error?.status == .internalServerError)
    }

    @Test("A Pydantic discriminated union parses and conforms")
    func discriminatedUnion() throws {
        // `to_strict_json_schema` output for `pet: Annotated[Cat | Dog, Field(discriminator="kind")]`.
        let schema = ##"""
            {"$defs": {"Cat": {"properties": {"kind": {"const": "cat", "title": "Kind", "type": "string"}, "note": {"anyOf": [{"type": "string"}, {"type": "null"}], "title": "Note"}}, "required": ["kind", "note"], "title": "Cat", "type": "object", "additionalProperties": false}, "Dog": {"properties": {"kind": {"const": "dog", "title": "Kind", "type": "string"}, "note": {"anyOf": [{"type": "string"}, {"type": "null"}], "title": "Note"}}, "required": ["kind", "note"], "title": "Dog", "type": "object", "additionalProperties": false}}, "properties": {"pet": {"discriminator": {"mapping": {"cat": "#/$defs/Cat", "dog": "#/$defs/Dog"}, "propertyName": "kind"}, "oneOf": [{"$ref": "#/$defs/Cat"}, {"$ref": "#/$defs/Dog"}], "title": "Pet"}}, "required": ["pet"], "title": "Discriminated", "type": "object", "additionalProperties": false}
            """##
        let parsed = try JSONSchemaParser().parse(JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8)))
        _ = try GenerationSchemaBuilder.schema(
            name: "Discriminated", root: parsed.root, definitions: parsed.definitions)
        let content = try conform(#"{"pet": {"kind": "dog"}}"#, schema: schema)
        let pet = object("pet", in: content)
        #expect(pet.flatMap { value("kind", in: $0) } == .string("dog"))
        #expect(pet.flatMap { value("note", in: $0) } == .null)
    }

    private func object(_ key: String, in content: GeneratedContent) -> GeneratedContent? {
        guard case .structure(let properties, _) = content.kind else { return nil }
        return properties[key]
    }
}
