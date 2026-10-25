/// Wraps text into lines for terminal output.
public enum LineWrapping {
    /// Breaks `text` at spaces into lines of at most `width` characters,
    /// including their indentation.
    ///
    /// The first line starts with `indent`, and later lines with `hangingIndent`,
    /// which defaults to `indent`.
    /// A span in backticks, such as a command, stays on one line.
    /// A word that is too long for the width gets a line of its own.
    public static func wrap(
        _ text: String,
        width: Int,
        indent: String = "",
        hangingIndent: String? = nil
    ) -> [String] {
        let hangingIndent = hangingIndent ?? indent
        var lines: [String] = []
        var line = ""
        for word in words(in: text) {
            let prefix = lines.isEmpty ? indent : hangingIndent
            if line.isEmpty {
                line = word
            } else if prefix.count + line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(prefix + line)
                line = word
            }
        }
        if !line.isEmpty {
            lines.append((lines.isEmpty ? indent : hangingIndent) + line)
        }
        return lines
    }

    /// Breaks `text` like ``wrap(_:width:indent:hangingIndent:)``,
    /// but starts each sentence on a new line.
    public static func wrapSentences(_ text: String, width: Int, indent: String = "") -> [String] {
        sentences(in: text).flatMap { wrap($0, width: width, indent: indent) }
    }

    /// The sentences of `text`, split after each period that a space follows.
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var sentence = ""
        for word in text.split(separator: " ") {
            sentence += sentence.isEmpty ? String(word) : " " + word
            if word.hasSuffix(".") {
                sentences.append(sentence)
                sentence = ""
            }
        }
        if !sentence.isEmpty {
            sentences.append(sentence)
        }
        return sentences
    }

    /// The words of `text`, with each span in backticks kept as one word.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var isInCode = false
        for piece in text.split(separator: " ") {
            if isInCode, let last = words.last {
                words[words.count - 1] = last + " " + piece
            } else {
                words.append(String(piece))
            }
            if piece.filter({ $0 == "`" }).count % 2 == 1 {
                isInCode.toggle()
            }
        }
        return words
    }
}
