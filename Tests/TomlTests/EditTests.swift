import Testing
import Foundation
@testable import Toml

// The edit ops. Every result must itself be valid (re-parses, round-trips),
// with per-element banners travelling with their element and every
// untouched byte left verbatim.

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
        // The trailing `[z]` block gives the LAST element a separator too, so
        // every element has one and the swap is byte-exact (see the
        // last-element caveat in AnnotatedEdit.swift).
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
        // The `[top]` block keeps the AoT elements away from the document's
        // first content token, whose banner would be absorbed into the
        // never-moving doc leading and NOT travel.
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
        #expect(out.contains("# rule b\n[[rule]]\nname = \"b\""))
        #expect(out.contains("# rule a\n[[rule]]\nname = \"a\""))
        let bIdx = try #require(out.range(of: "name = \"b\""))
        let aIdx = try #require(out.range(of: "name = \"a\""))
        #expect(bIdx.lowerBound < aIdx.lowerBound)
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

    // MARK: - Set a value in place

    @Test func setValuePreservesFormatting() throws {
        let src = "[[r]]\n  name  =  \"a\"   # keep\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("z"), atArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "name").render()
        #expect(out == "[[r]]\n  name  =  \"z\"   # keep\n")
        #expect(try Toml.Annotated(parsing: out).render() == out)
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
        #expect(doc.settingValue(.int(9), atArrayOfTablesElement: ["r"],
                                 ordinal: 0, forKey: "a.b").render() == src)    // `key` is one literal segment, not a path
    }

    @Test func setValueDupKeyEditsFirst() throws {
        // Duplicate keys are invalid TOML, but the lossless DOM tiles them,
        // so the op must pick one deterministically: the FIRST match, the
        // same choice `Body.entry(forKey:)` makes.
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
        // Interior comments belong to the OLD value and go with it; only the
        // comment after the last content token survives.
        let src = "[[r]]\nxs = [ 1, # one\n  2 ]   # tail\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.array([.int(9)]), atArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "xs").render()
        #expect(out == "[[r]]\nxs = [9]   # tail\n")
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    @Test func setIsolateMatchOnFacetSectionsFixture() throws {
        // The real facet shape: an isolate desktop's `match` lives DIRECTLY
        // on the `[desktop.N]` table, never on a section. The value's quoting
        // style is the one thing allowed to change (encode always emits a
        // basic string).
        let src = try fixture("facet.sections")
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("app=Safari"),
                                   atTable: ["desktop", "2"], forKey: "match").render()
        let anchor = "match = 'app=Safari or app~=Chrome'   # live-edited at runtime"
        #expect(src.components(separatedBy: anchor).count - 1 == 1,
                "anchor must hit the fixture exactly once, or the assertion is vacuous")
        let expected = src.replacingOccurrences(
            of: anchor, with: "match = \"app=Safari\"   # live-edited at runtime")
        #expect(out == expected)
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    @Test func setLayoutOnNamedWorkspaceFixture() throws {
        let src = try fixture("facet.sections")
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("stack"),
                                   atArrayOfTablesElement: ["desktop", "1", "section"],
                                   ordinal: 0, forKey: "layout").render()
        // Anchored on the label+layout run: a bare `layout = "bsp"` also
        // matches the isolate table, and replacingOccurrences rewrites EVERY
        // hit.
        let anchor = "label = \"Main\"\nlayout = \"bsp\"\n"
        #expect(src.components(separatedBy: anchor).count - 1 == 1,
                "anchor must hit the fixture exactly once, or the assertion is vacuous")
        let expected = src.replacingOccurrences(
            of: anchor, with: "label = \"Main\"\nlayout = \"stack\"\n")
        #expect(out == expected)
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    // MARK: - Upsert a value

    @Test func upsertExistingKeySetsInPlace() throws {
        let src = "[[r]]\nname = \"a\"\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("b"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "name").render()
        #expect(out == "[[r]]\nname = \"b\"\n")
    }

    @Test func upsertMissingKeyAppendsInheritingSiblingStyle() throws {
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
        // The ONE case where a neighbouring byte changes.
        let src = "[[r]]\nx = 1"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("z"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "label").render()
        #expect(out == "[[r]]\nx = 1\nlabel = \"z\"\n")
    }

    @Test func upsertAppendKeepsCRLFWithoutBlankLine() throws {
        // "\r\n" folds into ONE Character in Swift: a Character-level
        // missing-terminator check would give a CRLF sibling a spurious
        // second terminator.
        let src = "[[r]]\r\na = 1\r\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("x"), inArrayOfTablesElement: ["r"],
                                     ordinal: 0, forKey: "label").render()
        #expect(out == "[[r]]\r\na = 1\r\nlabel = \"x\"\r\n")
    }

    @Test func upsertRefusesDottedSiblingCollision() throws {
        // `sub.x = 1` makes `sub` a dotted-key table; `sub = …` would be a
        // duplicate key.
        let src = "[[r]]\nsub.x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.upsertingValue(.int(9), inArrayOfTablesElement: ["r"],
                                   ordinal: 0, forKey: "sub").render() == src)
    }

    @Test func upsertRefusesOwnedSubBlockCollision() throws {
        // The element owns a `[r.sub]` block, so `sub` is already a table.
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
        // facet's use-case: name an unnamed workspace section from the GUI.
        // The fixture keeps its unlabeled section at ordinal 1.
        let src = try fixture("facet.sections")
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.upsertingValue(.string("Dev"),
                                     inArrayOfTablesElement: ["desktop", "1", "section"],
                                     ordinal: 1, forKey: "label").render()
        let anchor = "layout = \"stack\"\n"
        #expect(src.components(separatedBy: anchor).count - 1 == 1,
                "anchor must hit the fixture exactly once, or the assertion is vacuous")
        let expected = src.replacingOccurrences(of: anchor, with: anchor + "label = \"Dev\"\n")
        #expect(out == expected)
        #expect(try Toml.Annotated(parsing: out).render() == out)
    }

    // MARK: - Set an array value at a std table

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
        let out = try Toml.Annotated(parsing: "")
            .settingArrayValue([], atTable: ["tags"], forKey: "defined").render()
        #expect(out == "[tags]\ndefined = []\n")
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
        // A `[tags]` header after `[[tags]]` is a redefinition.
        let src = "[[tags]]\nname = \"a\"\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingArrayValue([.int(1)], atTable: ["tags"],
                                      forKey: "defined").render() == src)
        // An AoT PREFIX is refused too: a `[a.b]` header would be VALID TOML
        // but bind inside the LAST `[[a]]` element, never what the caller
        // meant.
        let src2 = "[[a]]\nx = 1\n"
        let doc2 = try Toml.Annotated(parsing: src2)
        #expect(doc2.settingArrayValue([.int(1)], atTable: ["a", "b"],
                                       forKey: "k").render() == src2)
    }

    @Test func setArrayValueRefusesKeyDefinedPathCollisions() throws {
        // A scalar, an inline table and a dotted-key table are all closed to
        // a later header (TOML 1.0).
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
        // A Character-level "ends with \n" check would miss the CRLF and add
        // a stray LF.
        let src = "x = 1\r\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingArrayValue([.string("a")],
                                        atTable: ["tags"], forKey: "defined").render()
        #expect(out == "x = 1\r\n\n[tags]\ndefined = [\"a\"]\n")
    }

    // MARK: - Set a scalar value at a std table

    @Test func setValueReplacesExistingKeepingComment() throws {
        // A literal-string old value becomes a basic string — the documented
        // `Toml.encode` spelling.
        let src = "[desktop.2]\ntype = \"isolate\"\nmatch = 'app=Safari' # keep\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("app~=Code"),
                                   atTable: ["desktop", "2"], forKey: "match").render()
        #expect(out == "[desktop.2]\ntype = \"isolate\"\nmatch = \"app~=Code\" # keep\n")
    }

    @Test func setValueAppendsToExistingTable() throws {
        // facet's shape: an isolate-desktop table whose config never spelled
        // `match`.
        let src = "[desktop.2]\ntype = \"isolate\"\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.settingValue(.string("app~=Chrome"),
                                   atTable: ["desktop", "2"], forKey: "match").render()
        #expect(out == "[desktop.2]\ntype = \"isolate\"\nmatch = \"app~=Chrome\"\n")
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
        let src = "[desktop.2]\nmatch.x = 1\n"
        let doc = try Toml.Annotated(parsing: src)
        #expect(doc.settingValue(.string("v"), atTable: ["desktop", "2"],
                                 forKey: "match").render() == src)
        let src2 = "[desktop.2]\ntype = \"isolate\"\n\n[desktop.2.match]\nx = 1\n"
        let doc2 = try Toml.Annotated(parsing: src2)
        #expect(doc2.settingValue(.string("v"), atTable: ["desktop", "2"],
                                  forKey: "match").render() == src2)
    }

    @Test func setValueLeavesOtherBlocksByteIdentical() throws {
        let src = """
        # banner

        [[desktop.1.section]]
        label = "Main"   # first

        [desktop.2]
        type = "isolate"
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

        let doc2 = doc.reorderingArrayOfTables(at: path, [3, 2, 1, 0])
        let after = doc2.arrayOfTables(at: path)
        #expect(after.map { $0.body.entry(forKey: "name")?.value } == [
            .string("minimize"), .string("close window"),
            .string("reopen tab"), .string("close tab"),
        ])
        let reparsed = try Toml.Annotated(parsing: doc2.render())
        #expect(reparsed.render() == doc2.render())
        #expect(doc2.leading == doc.leading)          // the schema pragma never moves
        #expect(doc2.blocks.count == doc.blocks.count)
        #expect(doc.reorderingArrayOfTables(at: path, [0, 1, 2, 3]).render()
                == doc.render())
    }
}
