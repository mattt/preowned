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
