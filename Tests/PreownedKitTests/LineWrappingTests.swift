import Testing

@testable import PreownedKit

@Suite("Line wrapping")
struct LineWrappingTests {
    @Test("Text breaks at spaces within the width")
    func breaksAtSpaces() {
        let lines = LineWrapping.wrap("one two three four five", width: 9)
        #expect(lines == ["one two", "three", "four five"])
        #expect(lines.allSatisfy { $0.count <= 9 })
    }

    @Test("The first line takes the indent, and later lines the hanging indent")
    func indents() {
        let lines = LineWrapping.wrap("alpha beta gamma delta", width: 14, indent: "  ", hangingIndent: "    ")
        #expect(lines == ["  alpha beta", "    gamma", "    delta"])
    }

    @Test("A span in backticks stays on one line")
    func keepsCodeTogether() {
        let lines = LineWrapping.wrap("run `preowned serve --images=interactive` now", width: 20)
        #expect(lines == ["run", "`preowned serve --images=interactive`", "now"])
    }

    @Test("Each sentence starts on a new line")
    func sentences() {
        let lines = LineWrapping.wrapSentences("It failed. Run it again with a flag.", width: 20, indent: "  ")
        #expect(lines == ["  It failed.", "  Run it again with", "  a flag."])
    }

    @Test("Text that fits stays on one line, and empty text has no lines")
    func shortText() {
        #expect(LineWrapping.wrap("available", width: 80, indent: "  ") == ["  available"])
        #expect(LineWrapping.wrap("", width: 80).isEmpty)
    }
}
