import Testing
import Foundation
@testable import Toml

// The minimal edit ops (brief Q3): reorder / delete array-of-tables elements,
// delete a std table. Each returns a NEW document and the result must itself
// be valid (re-parses, round-trips), with per-element banners travelling with
// their element.

@Suite struct EditTests {

    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"),
            "missing fixture \(name).toml"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Reorder

    @Test func reorderSwapIsExactWhenSeparatorsUniform() throws {
        // When every element is followed by a blank-line separator (here the
        // AoT is followed by another block), reorder is byte-clean: bodies
        // swap and the uniform separators stay.
        let src = """
        [[rule]]
        name = "a"

        [[rule]]
        name = "b"

        [z]
        end = 1
        """
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.arrayOfTablesCount(at: ["rule"]) == 2)
        let out = doc.reorderingArrayOfTables(at: ["rule"], [1, 0]).render()
        #expect(out == """
        [[rule]]
        name = "b"

        [[rule]]
        name = "a"

        [z]
        end = 1
        """)
    }

    @Test func reorderCarriesPerElementBanner() throws {
        // A per-element banner comment travels with its element (the family's
        // [[exclude]] blocks each carry an explaining comment). The `[top]`
        // block ensures the AoT elements are not the document's first content
        // (whose banner would be absorbed into the never-moving doc leading).
        let src = """
        [top]
        k = 1

        # rule a
        [[rule]]
        name = "a"

        # rule b
        [[rule]]
        name = "b"

        """
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.reorderingArrayOfTables(at: ["rule"], [1, 0]).render()
        // each banner is now immediately above its own element's header
        #expect(out.contains("# rule b\n[[rule]]\nname = \"b\""))
        #expect(out.contains("# rule a\n[[rule]]\nname = \"a\""))
        // order actually swapped
        let bIdx = try #require(out.range(of: "name = \"b\""))
        let aIdx = try #require(out.range(of: "name = \"a\""))
        #expect(bIdx.lowerBound < aIdx.lowerBound)
        // [top] untouched, result re-parses
        #expect(out.hasPrefix("[top]\nk = 1"))
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    @Test func identityReorderIsByteIdentical() throws {
        let src = "[[r]]\nx = 1\n\n[[r]]\nx = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.reorderingArrayOfTables(at: ["r"], [0, 1]).render() == src)
    }

    @Test func invalidPermutationIsNoOp() throws {
        let src = "[[r]]\nx = 1\n[[r]]\nx = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.reorderingArrayOfTables(at: ["r"], [0]).render() == src)        // wrong length
        #expect(doc.reorderingArrayOfTables(at: ["r"], [0, 0]).render() == src)     // not a permutation
        #expect(doc.reorderingArrayOfTables(at: ["nope"], [0, 1]).render() == src)  // no such AoT
    }

    @Test func reorderPreservesSurroundingBlocks() throws {
        // A std table before and after the AoT must be untouched.
        let src = """
        [top]
        k = 1

        [[r]]
        n = "a"

        [[r]]
        n = "b"

        [bottom]
        z = 9
        """
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.reorderingArrayOfTables(at: ["r"], [1, 0]).render()
        #expect(out.contains("[top]\nk = 1"))
        #expect(out.contains("[bottom]\nz = 9"))
        // re-parses and the bodies swapped
        let doc2 = try Toml.Annotated(parsing: out)
        let rs = doc2.arrayOfTables(at: ["r"])
        #expect(rs.count == 2)
        #expect(rs[0].body.entry(forKey: "n")?.value == .string("b"))
        #expect(rs[1].body.entry(forKey: "n")?.value == .string("a"))
    }

    // MARK: - Delete

    @Test func deleteMiddleElement() throws {
        let src = "[[r]]\nx = 1\n\n[[r]]\nx = 2\n\n[[r]]\nx = 3\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.removingArrayOfTablesElement(at: ["r"], ordinal: 1).render()
        #expect(out == "[[r]]\nx = 1\n\n[[r]]\nx = 3\n")
    }

    @Test func deleteOutOfRangeIsNoOp() throws {
        let src = "[[r]]\nx = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.removingArrayOfTablesElement(at: ["r"], ordinal: 5).render() == src)
    }

    @Test func deleteStdTable() throws {
        let src = "[a]\nx = 1\n\n[b]\ny = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.removingTable(at: ["b"]).render()
        #expect(out == "[a]\nx = 1\n\n")
    }

    // MARK: - On a real config (wand's 4 cursor rules)

    // MARK: - Set a value in place (v2.1.0)

    @Test func setValuePreservesFormatting() throws {
        // Indent, `=` spacing, the inline comment and the terminator all
        // survive — only the value token is replaced (the crux of facet's
        // config auto-persist).
        let src = "[[r]]\n  name  =  \"a\"   # keep\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("z"), atArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "name").render()
        #expect(out == "[[r]]\n  name  =  \"z\"   # keep\n")
        #expect(try Toml.Annotated(parsing: out).render() == out)
        // A type change re-encodes the token, same formatting contract.
        let out2 = doc.settingValue(.int(5), atArrayOfTablesElement: ["r"],
                                    ordinal: 0, forKey: "name").render()
        #expect(out2 == "[[r]]\n  name  =  5   # keep\n")
    }

    @Test func setValueMissesAreNoOps() throws {
        let src = "[[r]]\nx = 1\na.b = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingValue(.int(9), atArrayOfTablesElement: ["r"],
                                 ordinal: 0, forKey: "nope").render() == src)   // key miss
        #expect(doc.settingValue(.int(9), atArrayOfTablesElement: ["r"],
                                 ordinal: 3, forKey: "x").render() == src)      // ordinal miss
        #expect(doc.settingValue(.int(9), atArrayOfTablesElement: ["nope"],
                                 ordinal: 0, forKey: "x").render() == src)      // no such AoT
        // `key` is ONE literal segment — it never matches a dotted entry
        // (`a.b = 2` is the path ["a","b"], not the key "a.b").
        #expect(doc.settingValue(.int(9), atArrayOfTablesElement: ["r"],
                                 ordinal: 0, forKey: "a.b").render() == src)
    }

    @Test func setValueDupKeyEditsFirst() throws {
        // Duplicate keys are invalid TOML but the lossless DOM tiles them;
        // set targets the FIRST match (mirrors `Body.entry(forKey:)`).
        let src = "[[r]]\nx = 1\nx = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.int(9), atArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "x").render()
        #expect(out == "[[r]]\nx = 9\nx = 2\n")
    }

    @Test func setValueKeepsCRLF() throws {
        let src = "[[r]]\r\nname = \"a\"\r\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("b"), atArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "name").render()
        #expect(out == "[[r]]\r\nname = \"b\"\r\n")
    }

    @Test func setValueCollapsesMultilineArrayKeepsTailComment() throws {
        // Replacing a multi-line array rewrites the whole value span (interior
        // comments belong to the OLD value and go with it); the comment after
        // the last content survives.
        let src = "[[r]]\nxs = [ 1, # one\n  2 ]   # tail\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.array([.int(9)]), atArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "xs").render()
        #expect(out == "[[r]]\nxs = [9]   # tail\n")
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    @Test func setLensMatchOnFacetSectionsFixture() throws {
        // The real facet shape: rewrite a lens `match` in place; every other
        // byte of the file is untouched (quoting style of the VALUE is the
        // one thing that changes — encode always emits a basic string).
        let src = try fixture("facet.sections")
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("app=Safari"),
                                   atArrayOfTablesElement: ["desktop", "1", "section"],
                                   ordinal: 2, forKey: "match").render()
        let expected = src.replacingOccurrences(
            of: "match = 'app=Safari or app~=Chrome'   # live-edited at runtime",
            with: "match = \"app=Safari\"   # live-edited at runtime")
        #expect(out == expected)
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    // MARK: - Upsert a value (v2.1.0)

    @Test func upsertExistingKeySetsInPlace() throws {
        let src = "[[r]]\nname = \"a\"\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("b"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "name").render()
        #expect(out == "[[r]]\nname = \"b\"\n")
    }

    @Test func upsertMissingKeyAppendsInheritingSiblingStyle() throws {
        // The new entry lands after the element's last entry — BEFORE the
        // blank-line separator (the body's trailing) — inheriting the
        // sibling's indent and terminator.
        let src = "[[r]]\n  a = 1\n\n[[r]]\n  b = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("x"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "label").render()
        #expect(out == "[[r]]\n  a = 1\n  label = \"x\"\n\n[[r]]\n  b = 2\n")
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    @Test func upsertIntoEmptyElementBody() throws {
        let src = "[[r]]\n\n[[r]]\nb = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.int(1), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "a").render()
        #expect(out == "[[r]]\na = 1\n\n[[r]]\nb = 2\n")
    }

    @Test func upsertNormalizesMissingFinalNewline() throws {
        // A final entry with no terminator (EOF) gets one added so the new
        // entry starts on its own line — the ONE case where a neighbouring
        // byte changes.
        let src = "[[r]]\nx = 1"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("z"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "label").render()
        #expect(out == "[[r]]\nx = 1\nlabel = \"z\"\n")
    }

    @Test func upsertAppendKeepsCRLFWithoutBlankLine() throws {
        // "\r\n" folds into ONE Character in Swift — the missing-terminator
        // check must be scalar-level or a CRLF sibling gains a spurious
        // second terminator (blank line + neighbour bytes mutated).
        let src = "[[r]]\r\na = 1\r\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("x"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "label").render()
        #expect(out == "[[r]]\r\na = 1\r\nlabel = \"x\"\r\n")
    }

    @Test func upsertRefusesDottedSiblingCollision() throws {
        // `sub.x = 1` defines `sub` as a dotted-key table; appending `sub = …`
        // would render invalid TOML (duplicate key) → no-op.
        let src = "[[r]]\nsub.x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.upsertingValue(.int(9), inArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "sub").render() == src)
    }

    @Test func upsertRefusesOwnedSubBlockCollision() throws {
        // The element owns a `[r.sub]` block; appending `sub = …` to the
        // element body would render invalid TOML (`sub` is a table) → no-op.
        let src = "[[r]]\na = 1\n\n[r.sub]\nz = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.upsertingValue(.int(9), inArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "sub").render() == src)
    }

    @Test func upsertOrdinalMissIsNoOp() throws {
        let src = "[[r]]\nx = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.upsertingValue(.int(2), inArrayOfTablesElement: ["r"],
                                   ordinal: 1, forKey: "x").render() == src)
        #expect(doc.upsertingValue(.int(2), inArrayOfTablesElement: ["nope"],
                                   ordinal: 0, forKey: "x").render() == src)
    }

    @Test func upsertLabelIntoUnnamedWorkspaceFixture() throws {
        // facet's use-case: name an unnamed workspace section from the GUI —
        // `label` is upserted into the element that has none.
        let src = try fixture("facet.sections")
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("Dev"),
                                     inArrayOfTablesElement: ["desktop", "1", "section"],
                                     ordinal: 1, forKey: "label").render()
        let expected = src.replacingOccurrences(
            of: "type = \"workspace\"\nlayout = \"bsp\"\n",
            with: "type = \"workspace\"\nlayout = \"bsp\"\nlabel = \"Dev\"\n")
        #expect(out == expected)
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    // MARK: - Set an array value at a std table (v2.1.0)

    @Test func setArrayValueReplacesExistingKeepingComment() throws {
        let src = "[tags]\ndefined = [\"a\"] # keep\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingArrayValue([.string("x"), .string("y")],
                                        atTable: ["tags"], forKey: "defined").render()
        #expect(out == "[tags]\ndefined = [\"x\", \"y\"] # keep\n")
    }

    @Test func setArrayValueAppendsToExistingTable() throws {
        let src = "[tags]\nother = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingArrayValue([.string("a")],
                                        atTable: ["tags"], forKey: "defined").render()
        #expect(out == "[tags]\nother = 1\ndefined = [\"a\"]\n")
    }

    @Test func setArrayValueCreatesTableAtEnd() throws {
        // No `[tags]` anywhere → a new block is appended: one separator blank
        // (the block's leading), a newline-terminated header, the entry.
        let src = "x = 1\n\n[z]\ny = 2\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingArrayValue([.string("a")],
                                        atTable: ["tags"], forKey: "defined").render()
        #expect(out == "x = 1\n\n[z]\ny = 2\n\n[tags]\ndefined = [\"a\"]\n")
        let doc2 = try Toml.Annotated(parsing: out)
        #expect(doc2.blocks.last?.body.entry(forKey: "defined")?.value
                == .array([.string("a")]))
        #expect(doc2.render() == out)
    }

    @Test func setArrayValueCreatesTableInEmptyDoc() throws {
        // Empty document → no separator blank; empty array renders as `[]`.
        let out = try Toml.Annotated(parsing: "")
            .settingArrayValue([], atTable: ["tags"], forKey: "defined").render()
        #expect(out == "[tags]\ndefined = []\n")
        // A path segment that needs quoting goes through encodeKey.
        let out2 = try Toml.Annotated(parsing: "")
            .settingArrayValue([], atTable: ["a.b"], forKey: "k").render()
        #expect(out2 == "[\"a.b\"]\nk = []\n")
    }

    @Test func setArrayValueNormalizesNoFinalNewline() throws {
        let src = "x = 1"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingArrayValue([.string("a")],
                                        atTable: ["tags"], forKey: "defined").render()
        #expect(out == "x = 1\n\n[tags]\ndefined = [\"a\"]\n")
    }

    @Test func setArrayValueEmptyPathIsNoOp() throws {
        let src = "x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingArrayValue([.int(1)], atTable: [], forKey: "k").render() == src)
    }

    @Test func setArrayValueRefusesAoTCollision() throws {
        // `path` already exists as an ARRAY-of-tables — creating a `[path]`
        // std table would render invalid TOML (redefinition), so the op is a
        // no-op (the mandate: never emit invalid TOML from a valid doc).
        let src = "[[tags]]\nname = \"a\"\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingArrayValue([.int(1)], atTable: ["tags"],
                                      forKey: "defined").render() == src)
        // A path whose PREFIX is an AoT is refused too: a `[a.b]` header
        // would bind inside the LAST `[[a]]` element, not at root — never
        // what the caller meant.
        let src2 = "[[a]]\nx = 1\n"
        let doc2 = try Toml.Annotated(parsing: src2)
        #expect(doc2.settingArrayValue([.int(1)], atTable: ["a", "b"],
                                       forKey: "k").render() == src2)
    }

    @Test func setArrayValueRefusesKeyDefinedPathCollisions() throws {
        // Creating a `[path]` header where any segment of `path` is already
        // KEY-defined (a scalar, an inline table, or a dotted key — all
        // closed to headers) would render invalid TOML → no-op.
        for (src, path) in [
            ("tags = 1\n",                 ["tags"]),            // scalar
            ("tags = { x = 1 }\n",         ["tags"]),            // inline table
            ("tags.defined = [1]\n",       ["tags"]),            // dotted key at root
            ("a = 1\n",                    ["a", "b"]),          // scalar prefix
            ("[a]\nb.c = 1\n",             ["a", "b"]),          // dotted key in a block
        ] {
            let doc = try Toml.Annotated(parsing: src)
            #expect(doc.settingArrayValue([.string("z")], atTable: path,
                                          forKey: "defined").render() == src,
                    "expected no-op for \(src)")
        }
    }

    @Test func setArrayValueRefusesKeyCollisionsInExistingTable() throws {
        // The table exists but `key` is already defined there another way —
        // a dotted entry (`defined.inner = …`) or a sub-table header
        // (`[tags.defined]`). Appending `defined = […]` would render invalid
        // TOML → no-op.
        let dotted = "[tags]\ndefined.inner = 1\n"
        let doc1 = try Toml.Annotated(parsing: dotted)
        #expect(doc1.settingArrayValue([.string("z")], atTable: ["tags"],
                                       forKey: "defined").render() == dotted)
        let subTable = "[tags]\nx = 1\n\n[tags.defined]\ny = 2\n"
        let doc2 = try Toml.Annotated(parsing: subTable)
        #expect(doc2.settingArrayValue([.string("z")], atTable: ["tags"],
                                       forKey: "defined").render() == subTable)
    }

    @Test func setArrayValueCreateKeepsCRLFDocEnd() throws {
        // A CRLF-terminated document already ends with a newline — the
        // normalization must not add a stray LF (scalar-level check).
        let src = "x = 1\r\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingArrayValue([.string("a")],
                                        atTable: ["tags"], forKey: "defined").render()
        #expect(out == "x = 1\r\n\n[tags]\ndefined = [\"a\"]\n")
    }

    // MARK: - Set a scalar value at a std table (v2.2.0)

    @Test func setValueReplacesExistingKeepingComment() throws {
        // Only the value token moves; the same-line comment, indent and `=`
        // spacing stay verbatim. A literal-string old value becomes a basic
        // string (the documented `Toml.encode` spelling).
        let src = "[desktop.2]\ntype = \"lens\"\nmatch = 'app=Safari' # keep\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("app~=Code"),
                                   atTable: ["desktop", "2"], forKey: "match").render()
        #expect(out == "[desktop.2]\ntype = \"lens\"\nmatch = \"app~=Code\" # keep\n")
    }

    @Test func setValueAppendsToExistingTable() throws {
        // The facet t-sgqk shape: a lens-desktop table whose config never
        // spelled `match` gets one appended after the last entry.
        let src = "[desktop.2]\ntype = \"lens\"\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("app~=Chrome"),
                                   atTable: ["desktop", "2"], forKey: "match").render()
        #expect(out == "[desktop.2]\ntype = \"lens\"\nmatch = \"app~=Chrome\"\n")
    }

    @Test func setValueCreatesTableAtEnd() throws {
        let src = "x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.bool(true), atTable: ["flags"], forKey: "on").render()
        #expect(out == "x = 1\n\n[flags]\non = true\n")
        let doc2 = try Toml.Annotated(parsing: out)
        #expect(doc2.blocks.last?.body.entry(forKey: "on")?.value == .bool(true))
        #expect(doc2.render() == out)
    }

    @Test func setValueEmptyPathIsNoOp() throws {
        let src = "x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingValue(.int(1), atTable: [], forKey: "k").render() == src)
    }

    @Test func setValueRefusesKeyCollisions() throws {
        // A dotted sibling (`match.x`) already defines `match` as a
        // dotted-key table — appending `match = …` would be invalid TOML.
        let src = "[desktop.2]\nmatch.x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingValue(.string("v"), atTable: ["desktop", "2"],
                                 forKey: "match").render() == src)
        // A sub-block `[desktop.2.match]` claims the key the same way.
        let src2 = "[desktop.2]\ntype = \"lens\"\n\n[desktop.2.match]\nx = 1\n"
        let doc2 = try Toml.Annotated(parsing: src2)
        #expect(doc2.settingValue(.string("v"), atTable: ["desktop", "2"],
                                  forKey: "match").render() == src2)
    }

    @Test func setValueLeavesOtherBlocksByteIdentical() throws {
        // Editing one table's value leaves every other block — comments,
        // blank lines, the AoT sections — byte-for-byte untouched.
        let src = """
        # banner

        [[desktop.1.section]]
        label = "Main"   # first

        [desktop.2]
        type = "lens"
        match = 'app=Safari'

        [theme]
        name = "terminal"
        """ + "\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("tag~=web"),
                                   atTable: ["desktop", "2"], forKey: "match").render()
        #expect(out == src.replacingOccurrences(
            of: "match = 'app=Safari'", with: "match = \"tag~=web\""))
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    // MARK: - On a real config (wand's 4 cursor rules)

    @Test func reorderRealWandCursorRules() throws {
        let doc = try Toml.Annotated(parsing: try fixture("wand.config"))
        let path = ["cast", "cursor", "rule"]
        let before = doc.arrayOfTables(at: path)
        #expect(before.count == 4)
        #expect(before[0].body.entry(forKey: "name")?.value == .string("close tab"))
        #expect(before[3].body.entry(forKey: "name")?.value == .string("minimize"))

        // Reverse the four rules.
        let doc2 = doc.reorderingArrayOfTables(at: path, [3, 2, 1, 0])
        let after = doc2.arrayOfTables(at: path)
        #expect(after.map { $0.body.entry(forKey: "name")?.value } == [
            .string("minimize"), .string("close window"),
            .string("reopen tab"), .string("close tab"),
        ])
        // The result re-parses and is itself round-trip stable.
        let reparsed = try Toml.Annotated(parsing: doc2.render())
        #expect(reparsed.render() == doc2.render())
        // Everything outside the rule run is unchanged: the file still has its
        // schema pragma and the same number of blocks.
        #expect(doc2.leading == doc.leading)
        #expect(doc2.blocks.count == doc.blocks.count)
        // An identity reorder leaves the whole file byte-identical.
        #expect(doc.reorderingArrayOfTables(at: path, [0, 1, 2, 3]).render()
                == doc.render())
    }
}
