import Foundation

/// Shared JSON coders for the wire types.
///
/// The wire types declare their own snake case coding keys,
/// so the coders use the default key strategies.
enum JSONCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
