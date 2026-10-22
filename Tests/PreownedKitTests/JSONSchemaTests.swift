import Foundation
import FoundationModels
import Testing

@testable import PreownedKit

@Suite("JSON Schema conversion")
struct JSONSchemaTests {
    private func parse(_ json: String) throws -> JSONSchemaParser.Result {
        try JSONSchemaParser().parse(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    private func rejection(_ json: String) -> String? {
        let error = #expect(throws: OpenAIError.self) {
            try parse(json)
        }
        #expect(error?.status == .badRequest)
        #expect(error?.param == "response_format")
        return error?.message
    }

    @Test("Objects keep required properties first, in order, then the rest by name")
    func objects() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "description": "A person.",
              "properties": {
                "zip": {"type": "string", "pattern": "^[0-9]{5}$"},
                "name": {"type": "string", "description": "The full name."},
                "age": {"type": "integer", "minimum": 0, "exclusiveMaximum": 151},
                "score": {"type": "number", "maximum": 1.5},
                "active": {"type": "boolean"}
              },
              "required": ["name", "age"],
              "additionalProperties": false
            }
            """#
        )
        let expected = SchemaObject(
            description: "A person.",
            properties: [
                SchemaProperty(
                    name: "name", description: "The full name.", schema: .string(choices: nil, pattern: nil)),
                SchemaProperty(name: "age", schema: .integer(minimum: 0, maximum: 150)),
                SchemaProperty(name: "active", schema: .boolean, isOptional: true),
                SchemaProperty(name: "score", schema: .number(minimum: nil, maximum: 1.5), isOptional: true),
                SchemaProperty(name: "zip", schema: .string(choices: nil, pattern: "^[0-9]{5}$"), isOptional: true),
            ]
        )
        #expect(result.root == .object(expected))
        #expect(result.definitions.isEmpty)
    }

    @Test("Enums, constants, arrays, and nullable types convert")
    func valueTypes() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "properties": {
                "color": {"enum": ["red", "green", null]},
                "kind": {"const": "fruit"},
                "tags": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 3},
                "note": {"type": ["string", "null"]}
              },
              "required": ["color", "kind", "tags", "note"]
            }
            """#
        )
        guard case .object(let object) = result.root else {
            Issue.record("The root is not an object.")
            return
        }
        #expect(
            object.properties == [
                SchemaProperty(
                    name: "color",
                    schema: .string(choices: ["red", "green"], pattern: nil),
                    isOptional: true,
                    isNullable: true
                ),
                SchemaProperty(name: "kind", schema: .string(choices: ["fruit"], pattern: nil)),
                SchemaProperty(
                    name: "tags",
                    schema: .array(items: .string(choices: nil, pattern: nil), minimumCount: 1, maximumCount: 3)
                ),
                SchemaProperty(
                    name: "note",
                    schema: .string(choices: nil, pattern: nil),
                    isOptional: true,
                    isNullable: true
                ),
            ]
        )
        #expect(object.representsNilExplicitly)
    }

    @Test("anyOf and oneOf become choices, and a null choice makes a property nullable")
    func choices() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "properties": {
                "value": {"anyOf": [{"type": "integer"}, {"type": "string"}]},
                "maybe": {"oneOf": [{"type": "integer"}, {"type": "null"}]}
              },
              "required": ["value", "maybe"]
            }
            """#
        )
        #expect(
            result.root
                == .object(
                    SchemaObject(properties: [
                        SchemaProperty(
                            name: "value",
                            schema: .anyOf(
                                [.integer(minimum: nil, maximum: nil), .string(choices: nil, pattern: nil)],
                                description: nil
                            )
                        ),
                        SchemaProperty(
                            name: "maybe",
                            schema: .integer(minimum: nil, maximum: nil),
                            isOptional: true,
                            isNullable: true
                        ),
                    ])
                )
        )
    }

    @Test("References resolve to definitions")
    func references() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "properties": {"root": {"$ref": "#/$defs/Node"}},
              "required": ["root"],
              "$defs": {
                "Node": {
                  "type": "object",
                  "properties": {
                    "name": {"type": "string"},
                    "children": {"type": "array", "items": {"$ref": "#/$defs/Node"}}
                  },
                  "required": ["name", "children"]
                }
              }
            }
            """#
        )
        #expect(result.definitions.keys.sorted() == ["Node"])
        #expect(
            result.root == .object(SchemaObject(properties: [SchemaProperty(name: "root", schema: .reference("Node"))]))
        )
    }

    @Test(
        "Unsupported schemas are rejected with the keyword and location",
        arguments: [
            (#"{"type": "string", "minLength": 1}"#, "`minLength`"),
            (
                #"{"type": "object", "properties": {"a": {"type": "string", "format": "email", "maxLength": 3}}}"#,
                "#/properties/a"
            ),
            (#"{"allOf": [{"type": "string"}]}"#, "`allOf`"),
            (#"{"type": "object", "additionalProperties": true}"#, "`additionalProperties`"),
            (#"{"type": "object", "additionalProperties": {"type": "string"}}"#, "`additionalProperties`"),
            (#"{"type": "object", "properties": {}, "required": ["missing"]}"#, "`missing`"),
            (#"{"type": "array"}"#, "`items`"),
            (#"{"type": "array", "items": [{"type": "string"}]}"#, "#/items"),
            (#"{"type": ["string", "integer"]}"#, "one type"),
            (#"{"type": ["string", "null"]}"#, "root"),
            (#"{"enum": [1, 2]}"#, "only for strings"),
            (#"{"type": "integer", "minimum": 1.5}"#, "`minimum`"),
            (#"{"type": "integer", "minimum": 5, "maximum": 1}"#, "greater"),
            (#"{"type": "string", "pattern": "("}"#, "regular expression"),
            (##"{"$ref": "#/$defs/Missing"}"##, "`Missing`"),
            (#"{"$ref": "https://example.com/schema.json"}"#, "`$ref`"),
            (#"{"description": "No type."}"#, "`type`"),
            (#"{"type": "null"}"#, "`null`"),
            (#"{"type": "date"}"#, "`date`"),
            (#"true"#, "JSON object"),
        ]
    )
    func rejections(json: String, fragment: String) {
        let message = rejection(json)
        #expect(message?.hasPrefix("Invalid JSON Schema at `#") == true)
        #expect(message?.contains(fragment) == true, "\(message ?? "nil") lacks \(fragment)")
    }

    @Test("A converted schema builds a GenerationSchema")
    func generationSchema() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "properties": {
                "name": {"type": "string", "pattern": "^[A-Z]"},
                "age": {"type": "integer", "minimum": 0, "maximum": 150},
                "height": {"type": "number", "minimum": 0},
                "color": {"enum": ["red", "green"]},
                "nickname": {"type": ["string", "null"]},
                "address": {
                  "type": "object",
                  "properties": {"city": {"type": "string"}},
                  "required": ["city"]
                },
                "pets": {
                  "type": "array",
                  "maxItems": 2,
                  "items": {
                    "type": "object",
                    "properties": {"kind": {"$ref": "#/$defs/Kind"}, "age": {"$ref": "#/$defs/Age"}},
                    "required": ["kind", "age"]
                  }
                },
                "value": {"anyOf": [{"type": "integer"}, {"type": "object", "properties": {"text": {"type": "string"}}}]},
                "tree": {"$ref": "#/$defs/Tree"}
              },
              "required": ["name", "age", "height", "color", "nickname", "address", "pets", "value", "tree"],
              "$defs": {
                "Kind": {"enum": ["cat", "dog"]},
                "Age": {"type": "integer", "minimum": 0},
                "Tree": {
                  "type": "object",
                  "properties": {"children": {"type": "array", "items": {"$ref": "#/$defs/Tree"}}},
                  "required": ["children"]
                }
              }
            }
            """#
        )
        let schema = try GenerationSchemaBuilder.schema(
            name: "Person",
            root: result.root,
            definitions: result.definitions
        )
        let json = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
        for name in ["name", "age", "height", "color", "nickname", "address", "city", "pets", "kind", "Tree"] {
            #expect(json.contains("\"\(name)\""), "The schema lacks \(name): \(json)")
        }
    }

    @Test("Generated names don't collide with definitions")
    func uniqueNames() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "properties": {
                "a": {"type": "object", "properties": {"x": {"type": "string"}}},
                "b": {"$ref": "#/$defs/Root_a"}
              },
              "$defs": {"Root_a": {"type": "object", "properties": {"y": {"type": "string"}}}}
            }
            """#
        )
        _ = try GenerationSchemaBuilder.schema(name: "Root", root: result.root, definitions: result.definitions)
    }

    @Test("A definition that contains itself without an object is rejected")
    func unnamedCycle() throws {
        let result = try parse(
            #"""
            {
              "type": "object",
              "properties": {"list": {"$ref": "#/$defs/List"}},
              "$defs": {"List": {"type": "array", "items": {"$ref": "#/$defs/List"}}}
            }
            """#
        )
        let error = #expect(throws: OpenAIError.self) {
            try GenerationSchemaBuilder.schema(name: "Root", root: result.root, definitions: result.definitions)
        }
        #expect(error?.message.contains("`List` refers to itself") == true)
    }
}
