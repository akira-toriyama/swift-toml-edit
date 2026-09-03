import Testing
import Foundation
@testable import Toml

// Regression tests for the 2026-07 adversarial audit's findings. Each was
// reproduced against the real toml-decode binary and cross-checked with the
// reference decoders (Python `tomllib`, go-toml v2). Every one lives in a
// blind spot of the other suites AND of toml-test 1.0, so these are the only
// guard.
@Suite struct AuditFixesTests {

    private func treeThrows(_ s: String, _ note: Comment? = nil, _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note, sourceLocation: loc) {
            _ = try Toml.Annotated(parsing: s).typedTree()
        }
    }

    // MARK: - F1 (redef) — a dotted key that extends an ALREADY-implicit
    // super-table SEALS it, so a later `[header]` on that exact path is a
    // duplicate-table redefinition (`tomllib` / go-toml both reject).

    @Test func dottedExtendOfImplicitSealsAgainstLaterHeader() {
        treeThrows("[a.b.c]\n[a]\nb.x = 1\n[a.b]\n", "dotted key b.x defined a.b; [a.b] redefines it")
        treeThrows("[a.b.c.d]\n[a]\nb.x = 1\n[a.b]\n", "deeper implicit, same seal")
        treeThrows("[g.a.b]\n[g]\na.x = 1\n[g.a]\n", "different path, same seal")
    }

    @Test func dottedExtendOfImplicitStillAllowsNewSubTablesAndPromotion() throws {
        // The seal must NOT over-reject (tomllib agrees on all four).
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.x = 1\n").typedTree()                  // no reopening header
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.x = 1\n[a.b.d]\ny = 2\n").typedTree()  // new sub-table d
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.x = 1\n[a.b.c.d]\ny = 2\n").typedTree()
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\n[a.b]\n").typedTree()                    // bare implicit→explicit
    }

    // MARK: - F2 (edit) — settingArrayValue's CREATE path (no `[path]` block
    // exists yet) must no-op when `key` is already a child block of `path`;
    // otherwise the appended `[path]` + `key = […]` duplicates that child.

    @Test func settingArrayValueRefusesChildKeyCollisionOnCreatePath() throws {
        for src in [
            "[[parent.arr]]\nx = 1\n",     // array-of-tables child
            "[parent.arr]\nx = 1\n",       // std sub-table child
            "[parent.arr.deep]\nx = 1\n",  // implicit child
        ] {
            let doc = try Toml.Annotated(parsing: src)
            let out = doc.settingArrayValue([.int(9)], atTable: ["parent"], forKey: "arr").render()
            #expect(out == src, "expected no-op for \(src)")
            _ = try Toml.Annotated(parsing: out).typedTree()
        }
    }

    // MARK: - F3 (edit) — an unrelated block interleaved between an AoT
    // element header and a sub-table it owns makes ownership NON-CONTIGUOUS;
    // a structural reorder / remove would strand the sub-table, so it no-ops.

    private let interleaved = "[[a]]\n[unrelated]\nz = 1\n[a.sub]\ny = 2\n[[a]]\n[a.sub]\nw = 3\n"

    @Test func reorderNonContiguousOwnershipIsNoOp() throws {
        let doc = try Toml.Annotated(parsing: interleaved)
        let out = doc.reorderingArrayOfTables(at: ["a"], [1, 0]).render()
        #expect(out == interleaved)
        _ = try Toml.Annotated(parsing: out).typedTree()
    }

    @Test func removeNonContiguousOwnershipIsNoOp() throws {
        let doc = try Toml.Annotated(parsing: interleaved)
        let out = doc.removingArrayOfTablesElement(at: ["a"], ordinal: 0).render()
        #expect(out == interleaved)
        _ = try Toml.Annotated(parsing: out).typedTree()
    }

    @Test func reorderContiguousOwnershipStillWorks() throws {
        // The guard must not over-reject the normal shape.
        let src = "[[a]]\nx = 1\n[a.sub]\nc = \"red\"\n[[a]]\nx = 2\n[a.sub]\nc = \"blue\"\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.reorderingArrayOfTables(at: ["a"], [1, 0]).render()
        #expect(out != src)
        guard case .table(let root) = try Toml.Annotated(parsing: out).typedTree(),
              case .array(let elems)? = root.first(where: { $0.key == "a" })?.value else {
            Issue.record("structure"); return
        }
        #expect(elems.count == 2)
        if case .table(let e0) = elems[0] {
            #expect(e0.first(where: { $0.key == "x" })?.value == .integer(2))
        } else { Issue.record("elem 0") }
    }

    // MARK: - F4 (lossy) — a `[std.sub]` header whose FIRST segment names an
    // existing array-of-tables is a sub-table of the AoT's LAST element
    // (TOML 1.0), NOT a plain table that overwrites the AoT node and drops
    // its sibling fields.

    @Test func lossyStdSubTableUnderArrayOfTables() throws {
        let root = try Toml.parse("[[bindings]]\ntrigger = \"a\"\n[bindings.when]\nmode = \"insert\"\n")
        let rows = try #require(root["bindings"]?.asArrayOfTables, "bindings must stay an array-of-tables")
        #expect(rows.count == 1)
        #expect(rows[0]["trigger"]?.asString == "a")
        #expect(rows[0]["when"]?.asTable?["mode"]?.asString == "insert")
    }

    // MARK: - F5 (lexer/decoder) — a lone CR (U+000D not part of CRLF) at a
    // value edge or interior is an invalid control char; a real CRLF stays
    // valid. The edge case is what a trim helper is tempted to swallow.

    @Test func loneCarriageReturnRejected() {
        treeThrows("a = 1\r", "bare CR after value")
        treeThrows("a = 1\r\r\n", "bare CR before a real CRLF")
        treeThrows("a = \"x\"\r", "bare CR after a string value")
        #expect(throws: (any Error).self, "interior bare CR in array") {
            _ = try Toml.decodeStrict("[1,\r2]")
        }
    }

    @Test func crlfStillAccepted() throws {
        _ = try Toml.Annotated(parsing: "a = 1\r\n").typedTree()
        #expect(try Toml.decodeStrict("[1,\r\n2]") == .array([.integer(1), .integer(2)]))
    }

    // MARK: - F6 (lossy) — the key/value and inline-table `=` split must be
    // quote-aware; a naive split on a quoted key CONTAINING `=` makes strict
    // `parse` throw and `parseFlat` drop the whole binding.

    @Test func lossyQuotedKeyContainingEquals() throws {
        #expect(try Toml.parse(#""a=b" = 1"# + "\n")["a=b"]?.asInt == 1)
        // The inline-table split is shared by `parse` and `parseFlat` via
        // `parseValue`; the sibling `c = 2` is what a mis-split loses.
        let strict = try #require(Toml.parse(#"m = { "a=b" = 1, c = 2 }"# + "\n")["m"]?.asTable)
        #expect(strict["a=b"]?.asInt == 1)
        #expect(strict["c"]?.asInt == 2)
        let flat = try #require(Toml.parseFlat(#"m = { "a=b" = 1, c = 2 }"# + "\n").tables[""]?["m"]?.asTable)
        #expect(flat["a=b"]?.asInt == 1)
        #expect(flat["c"]?.asInt == 2)
    }
}
