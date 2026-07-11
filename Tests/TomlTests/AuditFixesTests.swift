import Testing
import Foundation
@testable import Toml

// Regression tests for the correctness-audit findings (the 2026-07 multi-agent
// adversarial audit). Each finding was reproduced against the real toml-decode
// binary and cross-checked with reference decoders (Python `tomllib` and
// go-toml v2 — both toml-test reference implementations). Every one lives in a
// corpus / unit-test blind spot the existing 148 tests + the toml-test 1.0
// suite did not cover, so these are the durable guard.
@Suite struct AuditFixesTests {

    private func treeThrows(_ s: String, _ note: Comment? = nil, _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note, sourceLocation: loc) {
            _ = try Toml.Annotated(parsing: s).typedTree()
        }
    }

    // MARK: - F1 (redef) — a dotted key that extends an ALREADY-implicit
    // super-table SEALS it, so a later `[header]` on that exact path is a
    // duplicate-table redefinition and must be rejected. (`tomllib`/go-toml
    // both reject; the bare implicit→explicit promotion with no dotted key,
    // and NEW sub-tables under the sealed path, stay valid.)

    @Test func dottedExtendOfImplicitSealsAgainstLaterHeader() {
        treeThrows("[a.b.c]\n[a]\nb.x = 1\n[a.b]\n", "dotted key b.x defined a.b; [a.b] redefines it")
        treeThrows("[a.b.c.d]\n[a]\nb.x = 1\n[a.b]\n", "deeper implicit, same seal")
        treeThrows("[g.a.b]\n[g]\na.x = 1\n[g.a]\n", "different path, same seal")
    }

    @Test func dottedExtendOfImplicitStillAllowsNewSubTablesAndPromotion() throws {
        // The seal must NOT over-reject: a NEW sub-table under the sealed path,
        // deeper headers, and the bare promotion all stay valid (tomllib agrees).
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.x = 1\n").typedTree()                  // no reopening header
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.x = 1\n[a.b.d]\ny = 2\n").typedTree()  // new sub-table d
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\nb.x = 1\n[a.b.c.d]\ny = 2\n").typedTree()
        _ = try Toml.Annotated(parsing: "[a.b.c]\n[a]\n[a.b]\n").typedTree()                    // bare implicit→explicit
    }

    // MARK: - F2 (edit) — settingArrayValue's CREATE path (no `[path]` block
    // exists yet) must no-op when `key` is already a table / array-of-tables
    // child of `path`; otherwise it appends a `[path]` header + `key = […]`
    // that duplicates the existing child → invalid TOML from a valid document.

    @Test func settingArrayValueRefusesChildKeyCollisionOnCreatePath() throws {
        for src in [
            "[[parent.arr]]\nx = 1\n",     // `arr` is an array-of-tables child of parent
            "[parent.arr]\nx = 1\n",       // `arr` is a std sub-table child
            "[parent.arr.deep]\nx = 1\n",  // `arr` is an implicit child
        ] {
            let doc = try Toml.Annotated(parsing: src)
            let out = doc.settingArrayValue([.int(9)], atTable: ["parent"], forKey: "arr").render()
            #expect(out == src, "expected no-op for \(src)")
            _ = try Toml.Annotated(parsing: out).typedTree()   // and never invalid TOML
        }
    }

    // MARK: - F3 (edit) — an unrelated block interleaved between an AoT element
    // header and a sub-table it owns makes the element's ownership
    // NON-CONTIGUOUS; a structural reorder / remove cannot move it without
    // stranding the sub-table (invalid TOML or silent re-binding), so the op
    // is a safe no-op. The normal contiguous case must still work.

    private let interleaved = "[[a]]\n[unrelated]\nz = 1\n[a.sub]\ny = 2\n[[a]]\n[a.sub]\nw = 3\n"

    @Test func reorderNonContiguousOwnershipIsNoOp() throws {
        let doc = try Toml.Annotated(parsing: interleaved)
        let out = doc.reorderingArrayOfTables(at: ["a"], [1, 0]).render()
        #expect(out == interleaved)                          // no-op, not corruption
        _ = try Toml.Annotated(parsing: out).typedTree()     // still valid TOML
    }

    @Test func removeNonContiguousOwnershipIsNoOp() throws {
        let doc = try Toml.Annotated(parsing: interleaved)
        let out = doc.removingArrayOfTablesElement(at: ["a"], ordinal: 0).render()
        #expect(out == interleaved)
        _ = try Toml.Annotated(parsing: out).typedTree()
    }

    @Test func reorderContiguousOwnershipStillWorks() throws {
        // Guard: sub-tables placed immediately after their element header are
        // contiguous, so reorder must still swap them (unchanged behavior).
        let src = "[[a]]\nx = 1\n[a.sub]\nc = \"red\"\n[[a]]\nx = 2\n[a.sub]\nc = \"blue\"\n"
        let doc = try Toml.Annotated(parsing: src)
        let out = doc.reorderingArrayOfTables(at: ["a"], [1, 0]).render()
        #expect(out != src)                                  // it DID reorder
        guard case .table(let root) = try Toml.Annotated(parsing: out).typedTree(),
              case .array(let elems)? = root.first(where: { $0.key == "a" })?.value else {
            Issue.record("structure"); return
        }
        #expect(elems.count == 2)
        // the x=2 element (with c="blue") is now first
        if case .table(let e0) = elems[0] {
            #expect(e0.first(where: { $0.key == "x" })?.value == .integer(2))
        } else { Issue.record("elem 0") }
    }

    // MARK: - F4 (lossy) — a `[std.sub]` header whose FIRST segment names an
    // existing array-of-tables is a sub-table of the AoT's LAST element (TOML
    // 1.0), NOT a plain table that overwrites the AoT node and drops its
    // sibling fields. (Latent silent-corruption blind spot in `Toml.parse`.)

    @Test func lossyStdSubTableUnderArrayOfTables() throws {
        let root = try Toml.parse("[[bindings]]\ntrigger = \"a\"\n[bindings.when]\nmode = \"insert\"\n")
        let rows = try #require(root["bindings"]?.asArrayOfTables, "bindings must stay an array-of-tables")
        #expect(rows.count == 1)
        #expect(rows[0]["trigger"]?.asString == "a")                        // sibling field NOT lost
        #expect(rows[0]["when"]?.asTable?["mode"]?.asString == "insert")    // sub-table lands on the row
    }

    // MARK: - F5 (lexer/decoder) — a lone CR (U+000D not part of CRLF) at a
    // value edge or interior is an invalid control char and must be rejected;
    // a real CRLF stays valid. (Previously `asciiTrim` swallowed the lone CR.)

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

    // MARK: - F6 (lossy) — the key/value and inline-table `=` split is
    // quote-aware, so a quoted key that CONTAINS `=` is not mis-split (which
    // made strict `parse` throw and `parseFlat` drop the whole binding).

    @Test func lossyQuotedKeyContainingEquals() throws {
        // Strict parse: a top-level quoted key containing `=` splits on the REAL
        // separator, and the key is unquoted to `a=b` (not mis-split into `"a`).
        #expect(try Toml.parse(#""a=b" = 1"# + "\n")["a=b"]?.asInt == 1)
        // The inline-table entry split is the same quote-aware code path, shared
        // by both `parse` and `parseFlat` (via `parseValue`): EVERY entry
        // survives — including the sibling `c = 2` the old non-quote-aware split
        // dropped along with the whole table.
        let strict = try #require(Toml.parse(#"m = { "a=b" = 1, c = 2 }"# + "\n")["m"]?.asTable)
        #expect(strict["a=b"]?.asInt == 1)
        #expect(strict["c"]?.asInt == 2)
        let flat = try #require(Toml.parseFlat(#"m = { "a=b" = 1, c = 2 }"# + "\n").tables[""]?["m"]?.asTable)
        #expect(flat["a=b"]?.asInt == 1)
        #expect(flat["c"]?.asInt == 2)
    }
}
