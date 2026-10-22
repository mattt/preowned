/// Computes streaming deltas from cumulative snapshots.
///
/// Foundation Models streams snapshots of the whole response so far,
/// while OpenAI clients expect deltas to append.
/// The differ compares Unicode scalars, not characters,
/// so a combining mark that changes the last character
/// still produces a delta.
public struct SnapshotDiffer: Sendable {
    /// The text sent so far.
    public private(set) var emitted = ""

    public init() {}

    /// Returns the new text in a snapshot,
    /// or `nil` if the snapshot adds nothing.
    ///
    /// A client can't take back text that it received,
    /// so a snapshot that doesn't extend the emitted text produces no delta.
    /// A later snapshot that extends it again produces the remainder.
    public mutating func delta(for snapshot: String) -> String? {
        let scalars = snapshot.unicodeScalars
        guard scalars.starts(with: emitted.unicodeScalars) else { return nil }
        let added = scalars.dropFirst(emitted.unicodeScalars.count)
        guard !added.isEmpty else { return nil }
        emitted = snapshot
        return String(String.UnicodeScalarView(added))
    }
}

/// Turns cumulative text snapshots into the deltas of a streamed response.
///
/// Free text streams as deltas.
/// A `json_object` response can arrive in a Markdown code fence,
/// which the non-streaming path removes;
/// the fence is known only at the end,
/// so a `json_object` response is held back
/// and sent as one delta without the fence,
/// as a `json_schema` response is.
public struct TextSnapshotStream: Sendable {
    private let isJSONObject: Bool
    private var differ = SnapshotDiffer()
    private var latest = ""

    public init(format: ChatOutputFormat) {
        self.isJSONObject = format == .jsonObject
    }

    /// Returns the delta to send now for a snapshot, if any.
    public mutating func delta(for snapshot: String) -> String? {
        if isJSONObject {
            latest = snapshot
            return nil
        }
        return differ.delta(for: snapshot)
    }

    /// Returns the last delta to send, if any, and the whole response.
    public func finish() -> (delta: String?, content: String) {
        guard isJSONObject else {
            return (nil, differ.emitted)
        }
        let content = FoundationModelsChatService.removingCodeFence(from: latest)
        return (content.isEmpty ? nil : content, content)
    }
}
