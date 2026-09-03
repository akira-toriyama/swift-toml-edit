import Testing
import Foundation
@testable import Toml

// The lossless tiler over multi-line strings (`"""`/`'''`), whose body lines
// can look exactly like headers / key=values.
//
// Round-trip byte-identity is NECESSARY BUT NOT SUFFICIENT here: a mis-tiled
// body line can still concatenate back to the same bytes while the DOM is
// structurally wrong (a phantom Block / Entry), which corrupts any later edit
// or decode. So these tests assert the DOM SHAPE (entry / block counts, keys,
// no phantom nodes), not just `render() == source`.
@Suite struct MultilineStringTilerTests {

    private func parsed(_ s: String, _ loc: SourceLocation = #_sourceLocation) throws -> Toml.Annotated {
        let doc = try Toml.Annotated(parsing: s)
        #expect(doc.render() == s, "round-trip diverged", sourceLocation: loc)
        return doc
    }

    // Line-wise construction avoids escaping `"""` inside a Swift literal.
    private func toml(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

    // MARK: - Body lines that LOOK like structure must NOT become phantom nodes

    @Test func basicBodyLooksLikeHeaderAndKeyval() throws {
        let s = toml(
            #"x = """"#,           // x = """
            "[not a header]",
            "a = 1   # not a comment, not an entry",
            "]] also not a header",
            #"""""#                 // """
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 1)
        #expect(doc.blocks.isEmpty)
        #expect(doc.root.entries[0].key == ["x"])
    }

    @Test func literalBodyHasHashAndQuotes() throws {
        let s = toml(
            "re = '''",
            #"I [dw]on't need \d{2} escapes  # and this # is literal"#,
            "and a ' lone apostrophe",
            "'''",
            "after = 2"
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 2)
        #expect(doc.blocks.isEmpty)
        #expect(doc.root.entries.map(\.key) == [["re"], ["after"]])
    }

    // MARK: - The trailing-quote close rule (up to two quotes before the close)

    @Test func basicTrailingQuotesAndEscapes() throws {
        // Shapes from toml-test valid/string/multiline-quotes.
        let s = toml(
            #"one = """"one quote""""#,
            "five = \"\"\"",
            "Closing with five quotes",
            "\"\"\"\"\"",
            #"escaped = """lol\""""""#
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 3)
        #expect(doc.blocks.isEmpty)
        #expect(doc.root.entries.map(\.key) == [["one"], ["five"], ["escaped"]])
    }

    @Test func literalTrailingQuotes() throws {
        let s = toml(
            "lit_one = ''''one quote''''",
            "this = ''''",
            "' there's one already",
            "'' two more",
            "'''''"
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 2)
        #expect(doc.blocks.isEmpty)
    }

    // MARK: - Empty + line-ending-backslash + leading-newline forms

    @Test func emptyAndBackslashContinuation() throws {
        let s = toml(
            #"empty1 = """""""#,     // """""" → empty
            "empty2 = \"\"\"",
            "\"\"\"",                  // newline-after-open trimmed (semantic; bytes preserved)
            "folded = \"\"\"\\",       // line-ending backslash continuation
            "    \"\"\"",
            "next = 1"
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 4)
        #expect(doc.blocks.isEmpty)
        #expect(doc.root.entries.map(\.key) == [["empty1"], ["empty2"], ["folded"], ["next"]])
    }

    // MARK: - Interaction with real headers / blocks around a multi-line string

    @Test func multilineInsideTableThenNextBlock() throws {
        let s = toml(
            "[a]",
            "doc = \"\"\"",
            "line one",
            "[looks like a header but is string body]",
            "line three",
            "\"\"\"",
            "k = 1",
            "",
            "[b]",
            "y = 2"
        )
        let doc = try parsed(s)
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].path == ["a"])
        #expect(doc.blocks[1].path == ["b"])
        #expect(doc.blocks[0].body.entries.map(\.key) == [["doc"], ["k"]])
        #expect(doc.blocks[1].body.entries.map(\.key) == [["y"]])
    }

    // MARK: - CRLF inside a multi-line string body round-trips byte-for-byte

    @Test func crlfInMultilineBody() throws {
        let s = "x = \"\"\"\r\nline1\r\nline2\r\n\"\"\"\r\nafter = 1\r\n"
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 2)
        #expect(doc.blocks.isEmpty)
    }

    // MARK: - Regression: single-line strings and multi-line arrays still tile

    @Test func singleLineStringsUnaffected() throws {
        let s = toml(
            #"a = "has a # hash and an = inside""#,
            "b = 'literal with # and = too'",
            "c = 1"
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 3)
        #expect(doc.root.entries.map(\.key) == [["a"], ["b"], ["c"]])
        #expect(doc.root.entries[0].value == .string("has a # hash and an = inside"))
    }

    @Test func multilineArrayStillTiles() throws {
        let s = toml(
            "roles = [",
            #"    "Button","#,
            #"    "Link",     # inline comment"#,
            "]",
            "after = 1"
        )
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 2)
        #expect(doc.root.entries[0].key == ["roles"])
        #expect(doc.root.entries[0].value?.asStringArray == ["Button", "Link"])
    }

    // MARK: - Entry.value answers nil for a multi-line string spelling (t-fjr0)

    // The lenient decode rides parseFlat, whose naive quote model closes a
    // triple quote early and fabricates a plausible fragment (`"""` read as
    // the one-char string `"`). The tiler DOES hand such spellings to
    // `valueText`, so without the up-front rejection the fabricated value
    // reaches the public `Entry.value`, which promises nil outside the lossy
    // grammar.
    @Test func entryValueNilForMultilineStringSpellings() throws {
        for s in [
            "a = \"\"\"\nhello\n\"\"\"\n",
            "a = \"\"\"hello\"\"\"\n",
            "a = '''\nhi\n'''\n",
        ] {
            let doc = try parsed(s)
            let e = try #require(doc.root.entries.first)
            #expect(e.value == nil,
                    "fabricated \(String(describing: e.value)) for \(s.debugDescription)")
        }
    }

    // MARK: - A quoted key containing '=' splits on the real separator

    @Test func quotedKeyContainingEquals() throws {
        let s = #""a=b" = "v""# + "\n"
        let doc = try parsed(s)
        #expect(doc.root.entries.count == 1)
        #expect(doc.root.entries[0].key == ["a=b"])
        #expect(doc.root.entries[0].value == .string("v"))
    }
}
