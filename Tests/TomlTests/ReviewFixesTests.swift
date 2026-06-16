import Testing
import Foundation
@testable import Toml

// Regression tests for the bugs the M2 adversarial review confirmed — each lives
// in a corpus blind spot, so these are the durable guard.
@Suite struct ReviewFixesTests {

    private func parseThrows(_ s: String, _ note: Comment? = nil, _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note, sourceLocation: loc) { _ = try Toml.Annotated(parsing: s) }
    }
    private func decodeThrows(_ s: String, _ note: Comment? = nil, _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note, sourceLocation: loc) { _ = try Toml.decodeStrict(s) }
    }
    private func treeThrows(_ s: String, _ note: Comment? = nil, _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note, sourceLocation: loc) { _ = try Toml.Annotated(parsing: s).typedTree() }
    }

    // H1 — a lone CR (not part of CRLF) inside a multi-line string is invalid.
    @Test func loneCRInMultilineRejected() {
        decodeThrows("\"\"\"a\u{0D}b\"\"\"", "bare CR in multi-line basic")
        decodeThrows("'''a\u{0D}b'''", "bare CR in multi-line literal")
    }
    @Test func crlfInMultilineAccepted() throws {
        #expect(try Toml.decodeStrict("\"\"\"a\u{0D}\u{0A}b\"\"\"") == .string("a\u{0D}\u{0A}b"))
    }

    // H2 — a line of only non-ASCII whitespace, or a stray CR, is not blank.
    @Test func nonAsciiWhitespaceLineRejected() {
        parseThrows("x = 1\n\u{00A0}\ny = 2\n", "U+00A0-only line")
        parseThrows("x = 1\n\u{3000}\ny = 2\n", "U+3000-only line")
        parseThrows("x = 1\n\u{2002}\ny = 2\n", "U+2002-only line")
    }
    @Test func loneCRLineRejected() {
        // A CR NOT followed by LF (here at EOF) is a stray control char, not a
        // blank line. (CRLF, by contrast, is a valid empty line.)
        parseThrows("# c\n\u{0D}", "a lone-CR line is not blank")
    }
    @Test func ordinaryBlankLinesStillRoundTrip() throws {
        let s = "a = 1\n\n\t  \n[s]\nb = 2\n"
        #expect(try Toml.Annotated(parsing: s).render() == s)
    }

    // H3 — a dotted key MAY add a new sibling to an implicit super-table, but
    // MUST NOT extend a header-defined table.
    @Test func dottedExtendsImplicitSuperTable() throws {
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.a = 1\n").typedTree()
    }
    @Test func dottedCannotExtendHeaderTable() {
        treeThrows("[a.b.c]\nz = 9\n[a]\nb.c.t = 1\n", "extends header-defined a.b.c")
    }

    // M1 — control char in a comment on a multi-line continuation line.
    @Test func controlCharInContinuationCommentRejected() {
        parseThrows("a = [\n 1 #bad\u{01}\n]\n", "control char in array continuation comment")
        parseThrows("a = [\n#x\u{01}\n 1,\n]\n", "control char in comment-only continuation line")
    }
    @Test func validContinuationCommentAndHashInStringAccepted() throws {
        _ = try Toml.Annotated(parsing: "a = [\n 1, # fine\ttab ok\n]\n")
        // A `#` inside an open multi-line string body is content, not a comment.
        _ = try Toml.Annotated(parsing: "a = \"\"\"\nhas # hash\n\"\"\"\n")
    }

    // M2 — a finite float literal that overflows binary64 is rejected.
    @Test func floatOverflowRejected() {
        decodeThrows("1e400", "finite literal overflowing to inf")
    }
    @Test func floatInfinityStillAccepted() throws {
        #expect(try Toml.decodeStrict("inf") == .float(.infinity))
    }

    // L1/L2 — a non-table top-level value cannot be encoded as a document.
    @Test func nonTableRootEncodeThrows() {
        #expect(throws: (any Error).self) { _ = try Toml.TypedValue.integer(5).serializeDocument() }
        #expect(throws: (any Error).self) { _ = try Toml.TypedValue.array([.integer(5)]).serializeDocument() }
    }
    @Test func emptyTableRootEncodesToEmpty() throws {
        #expect(try Toml.TypedValue.table([]).serializeDocument() == "")
    }
}
