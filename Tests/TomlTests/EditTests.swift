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
