import Testing
import Foundation
@testable import Toml

// The core invariant of the lossless DOM: parse → render is byte-for-byte
// identical for anything we can parse. Covered by micro-fixtures (one per
// construct) and the family's real config.toml goldens. Named `RoundTrip*` so
// CI can isolate the check.

@Suite struct RoundTripTests {

    private func check(_ s: String, _ note: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let doc = try Toml.Annotated(parsing: s)
        let out = doc.render()
        #expect(out == s, note ?? "round-trip diverged", sourceLocation: sourceLocation)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"),
            "missing fixture \(name).toml"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Micro-fixtures (one per construct)

    @Test func empty() throws { try check("") }
    @Test func onlyNewline() throws { try check("\n") }
    @Test func keyvalNoTrailingNewline() throws { try check("x = 1") }
    @Test func keyvalTrailingNewline() throws { try check("x = 1\n") }

    @Test func commentsAndBlanks() throws {
        try check("""
        # leading comment
        # second line

        x = 1

        # banner

        y = 2
        """)
    }

    @Test func twoConsecutiveBlankLines() throws {
        // The family uses runs of up to 2 blank lines as section dividers;
        // they must not collapse.
        try check("a = 1\n\n\n[s]\nb = 2\n")
    }

    @Test func schemaPragmaLine1() throws {
        try check("""
        #:schema ./config.schema.json
        # header

        [border]
        effect = "neon"
        """)
    }

    @Test func stdTableAndDottedHeaders() throws {
        try check("""
        [a]
        x = 1
        [a.b.c]
        y = 2
        """)
    }

    @Test func quotedKeyHeader() throws {
        try check(#"""
        [behavior."com.apple.Safari"]
        roles = ["Link"]
        """#)
    }

    @Test func numericDottedHeaderAndInlineTable() throws {
        // A neutral shape on purpose: no family config ships an inline table,
        // so this case (and the fuzz grammar) is the construct's only guard,
        // and spelling it in a consumer's vocabulary would read as live usage.
        try check("""
        [panel.1]
        1 = { name = "Dev" }
        2 = { name = "Web" }
        """)
    }

    @Test func arrayOfTables() throws {
        try check("""
        [[cast.cursor.rule]]
        name = "close tab"
        apps = ["*chrome*", "*safari*"]

        [[cast.cursor.rule]]
        name = "minimize"
        """)
    }

    @Test func multilineArrayTrailingComma() throws {
        try check("""
        roles = [
            "Button",
            "MenuItem",
            "Link",
        ]
        after = 1
        """)
    }

    @Test func multilineArrayWithInnerComment() throws {
        try check("""
        [s]
        roles = [
            "Button",
            "MenuItem",   # inline comment inside the array
            "Link",
        ]
        """)
    }

    @Test func alignedInlineComments() throws {
        // The exact run of spaces before `#` is significant (column alignment).
        try check("""
        pad = 4            # gap between window edge and ring
        min-size = 80      # ignore windows smaller than this
        sound-volume = 0.3        # 0.0 … 1.0
        """)
    }

    @Test func emptyAndDisabledSentinels() throws {
        try check("""
        sound = ""
        apps = []
        effect = "off"
        """)
    }

    @Test func hexColorAndScalars() throws {
        try check("""
        color = "#39C5C8"
        width = 3
        glow = true
        ratio = 1.5
        """)
    }

    @Test func indentedContinuationComment() throws {
        // halo ends a block with an indented continuation comment line.
        try check("""
        pet-lap-seconds = 8       # seconds for a pet to circle the window once
                                  # (lower = faster chase, higher = lazier)
        """)
    }

    @Test func crlfLineEndings() throws {
        // The family configs are LF-only, so nothing else exercises CRLF.
        try check("# c\r\n[s]\r\nx = 1\r\n")
    }

    @Test func mixedLineEndings() throws {
        try check("a = 1\n[s]\r\nb = 2\n")
    }

    @Test func leadingAndTrailingBlankLines() throws {
        try check("\n\n# only trivia, no content\n\n")
    }

    @Test func literalString() throws {
        try check(#"cmd = 'cd ~/repo && git switch "{line}"'"# + "\n")
    }

    // MARK: - Real config goldens (the family's shipped config.toml files,
    // plus the hand-written facet sections fixture the edit ops are pinned to)

    @Test func roundTripStill() throws { try check(try fixture("still")) }
    @Test func roundTripHalo() throws { try check(try fixture("halo.config")) }
    @Test func roundTripChord() throws { try check(try fixture("chord.config")) }
    @Test func roundTripFacet() throws { try check(try fixture("facet.config")) }
    @Test func roundTripFacetSections() throws { try check(try fixture("facet.sections")) }
    @Test func roundTripPerch() throws { try check(try fixture("perch.config")) }
    @Test func roundTripWand() throws { try check(try fixture("wand.config")) }

    // MARK: - Structure sanity (the DOM is navigable, not just raw text)

    @Test func parsesStructure() throws {
        let doc = try Toml.Annotated(parsing: """
        #:schema ./x.json
        # header

        top = 1

        # the border section
        [border]
        effect = "neon"

        [[exclude]]
        app = "A"
        [[exclude]]
        app = "B"
        """)
        #expect(doc.leading.contains("#:schema"))
        #expect(doc.root.entry(forKey: "top")?.value == .int(1))
        #expect(doc.blocks.count == 3)
        #expect(doc.blocks[0].kind == .table)
        #expect(doc.blocks[0].path == ["border"])
        #expect(doc.blocks[1].kind == .arrayElement)
        #expect(doc.blocks[1].path == ["exclude"])
        #expect(doc.blocks[2].kind == .arrayElement)
        // The wand#129 split: the banner is [border]'s leading, the blank-line
        // separator before it stayed with the root body.
        #expect(doc.blocks[0].leading == "# the border section\n")
        #expect(doc.root.trailing.contains("\n"))
        #expect(doc.blocks[0].body.entry(forKey: "effect")?.value == .string("neon"))
    }
}
