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

    // H4/H5 — AoT edit ops must move/delete an element WITH the sub-tables it
    // owns, or nested tables rebind to the wrong element / orphan into invalid
    // TOML.

    /// The `name` field of each element of the array-of-tables `key`, after
    /// re-parsing `doc`'s rendered output through the typed tree.
    private func aotField(_ doc: Toml.Annotated, _ key: String, _ field: String) throws -> [String] {
        guard case .table(let root) = try Toml.Annotated(parsing: doc.render()).typedTree(),
              case .array(let elems)? = root.first(where: { $0.key == key })?.value else { return [] }
        return elems.compactMap { e -> String? in
            guard case .table(let kvs) = e, case .string(let s)? = kvs.first(where: { $0.key == field })?.value
            else { return nil }
            return s
        }
    }
    private func aotSubColor(_ doc: Toml.Annotated) throws -> [String] {
        guard case .table(let root) = try Toml.Annotated(parsing: doc.render()).typedTree(),
              case .array(let elems)? = root.first(where: { $0.key == "fruit" })?.value else { return [] }
        return elems.compactMap { e -> String? in
            guard case .table(let kvs) = e,
                  case .table(let phys)? = kvs.first(where: { $0.key == "physical" })?.value,
                  case .string(let c)? = phys.first(where: { $0.key == "color" })?.value else { return nil }
            return c
        }
    }

    @Test func removeAoTElementTakesOwnedSubTable() throws {
        let doc = try Toml.Annotated(parsing: """
        [[fruit]]
        name = "apple"

        [fruit.physical]
        color = "red"

        [[fruit]]
        name = "banana"

        """)
        let after = doc.removingArrayOfTablesElement(at: ["fruit"], ordinal: 0)
        // The apple element AND its [fruit.physical] are gone; only banana left,
        // and the result re-parses cleanly (no orphaned sub-table).
        #expect(try aotField(after, "fruit", "name") == ["banana"])
    }

    @Test func reorderAoTElementsCarryOwnedSubTables() throws {
        let doc = try Toml.Annotated(parsing: """
        [[fruit]]
        name = "apple"
        [fruit.physical]
        color = "red"
        [[fruit]]
        name = "banana"
        [fruit.physical]
        color = "yellow"

        """)
        let after = doc.reorderingArrayOfTables(at: ["fruit"], [1, 0])
        #expect(try aotField(after, "fruit", "name") == ["banana", "apple"])
        // Each color stays bound to its element (not left behind).
        #expect(try aotSubColor(after) == ["yellow", "red"])
    }

    // M4 — a single leading BOM is tolerated, round-trips byte-identically on
    // the lossless path, and does not corrupt the first key on the lossy path.
    @Test func leadingBOMRoundTripsAndDoesNotCorrupt() throws {
        let s = "\u{FEFF}x = 1\n"
        #expect(try Toml.Annotated(parsing: s).render() == s)
        #expect(try Toml.Annotated(parsing: s).render().unicodeScalars.first == "\u{FEFF}")
        // lossy path: first key is `x`, not `\u{FEFF}x`
        #expect(try Toml.parse(s)["x"]?.asInt == 1)
        #expect(Toml.parseFlat(s).tables[""]?["x"]?.asInt == 1)
    }
    @Test func bomMidDocumentNotStripped() {
        // A BOM that is NOT at offset 0 is a real (invalid) character in a key.
        parseThrows("x = 1\n\u{FEFF}y = 2\n", "mid-document BOM is invalid")
    }

    // M3 — a key whose NAME contains a literal dot is found by parts, and the
    // String overload treats its argument as dotted-path syntax.
    @Test func dotNamedKeyLookup() throws {
        let doc = try Toml.Annotated(parsing: #""a.b" = 1"# + "\n")
        #expect(doc.root.entry(forKeyParts: ["a.b"])?.value == .int(1))
        #expect(doc.root.entry(forKey: "a.b") == nil)          // parsed as path ["a","b"]
        #expect(doc.root.entry(forKey: #""a.b""#)?.value == .int(1))
    }

    // The DOM lookup splits via lexDottedPath, which DECODES basic-string
    // escapes per segment (the lossless side), unlike the lossy
    // splitDottedPath (literal — see LossyProjectionTests.lossyKeyEscapesStayLiteral).
    // So a `"a\tb"` lookup resolves to the escape-decoded key the strict
    // parser stored. Pins the finisher split that shares scanDottedSegments.
    @Test func dottedPathLookupDecodesKeyEscapes() throws {
        let doc = try Toml.Annotated(parsing: #""a\tb" = 1"# + "\n")
        #expect(doc.root.entry(forKey: #""a\tb""#)?.value == .int(1))
    }

    @Test func identityReorderIsByteStable() throws {
        let s = """
        [[r]]
        a = 1
        [r.sub]
        b = 2
        [[r]]
        a = 3

        """
        let doc = try Toml.Annotated(parsing: s)
        #expect(doc.reorderingArrayOfTables(at: ["r"], [0, 1]).render() == s)
    }
}
