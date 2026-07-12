import Testing
import Foundation
@testable import Toml

// `parseWithSpans` — the DOM-derived lossy parse (chord#159 / t-0030).
//
// Two contracts are locked here:
//
// 1. EQUIVALENCE (the unification gate): `parseWithSpans(s).tree` must equal
//    the proven line-based `parse(s)` — same tree, same `Row.span`s, or BOTH
//    throw — over the family's real configs, a hand corpus of edge cases, and
//    the shared fuzz grammar. The deliberate deltas, each pinned below:
//      • CRLF: the line-based `parse` never actually split CRLF (a Swift
//        `Character` folds "\r\n", so `split(separator: "\n")` sees one line
//        and throws); the DOM derivation handles CRLF correctly —
//        crlfDocumentSpansCountPhysicalLines.
//      • tiler strictness: invalid TOML the old scanner silently tolerated
//        (a control char in a comment, a degenerate `[]` header) now throws —
//        tilerStrictnessDeltasArePinned.
//
// 2. SPANS: per-entry key/value locations and per-header locations, exact to
//    the line AND column — the capability chord's column-precise warnings
//    need (`(config.toml:N:C)`).

// MARK: - Span exactness

@Test func entryAndHeaderSpans() throws {
    let r = try Toml.parseWithSpans("""
    top = 1
    [server]
      host = "x"   # c
    [[rule]]
    name = "a"
      [[rule]]
    name = "b"
    """)
    // The tree is the lossy `parse` tree, unchanged.
    #expect(r.tree["top"]?.asInt == 1)
    #expect(r.tree["server"]?.asTable?["host"]?.asString == "x")

    // Entries: key span at the key's first character, value span at the
    // value's first character (both 1-based, indentation-aware).
    #expect(r.entrySpans[[.key("top")]] ==
            Toml.EntrySpans(key: .init(line: 1, column: 1), value: .init(line: 1, column: 7)))
    #expect(r.entrySpans[[.key("server"), .key("host")]] ==
            Toml.EntrySpans(key: .init(line: 3, column: 3), value: .init(line: 3, column: 10)))
    #expect(r.entrySpans[[.key("rule"), .index(0), .key("name")]] ==
            Toml.EntrySpans(key: .init(line: 5, column: 1), value: .init(line: 5, column: 8)))
    #expect(r.entrySpans[[.key("rule"), .index(1), .key("name")]] ==
            Toml.EntrySpans(key: .init(line: 7, column: 1), value: .init(line: 7, column: 8)))

    // Headers: the `[` position. AoT elements also keep Row.span (unchanged).
    #expect(r.headerSpans[[.key("server")]] == Toml.SourceSpan(line: 2, column: 1))
    #expect(r.headerSpans[[.key("rule"), .index(0)]] == Toml.SourceSpan(line: 4, column: 1))
    #expect(r.headerSpans[[.key("rule"), .index(1)]] == Toml.SourceSpan(line: 6, column: 3))
    let rows = try #require(r.tree["rule"]?.asArrayOfTables)
    #expect(rows[1].span == Toml.SourceSpan(line: 6, column: 3))
}

@Test func dottedKeySpansAtLeaf() throws {
    let r = try Toml.parseWithSpans("""
    [a]
    b.c = 2
    """)
    #expect(r.tree["a"]?.asTable?["b"]?.asTable?["c"]?.asInt == 2)
    // One entry → one span, recorded at the LEAF path; the intermediate
    // table `b` gets none.
    #expect(r.entrySpans[[.key("a"), .key("b"), .key("c")]] ==
            Toml.EntrySpans(key: .init(line: 2, column: 1), value: .init(line: 2, column: 7)))
    #expect(r.entrySpans[[.key("a"), .key("b")]] == nil)
}

@Test func nestedAoTAndStdReopenSpans() throws {
    let r = try Toml.parseWithSpans("""
    [[srv]]
    tag = 1
    [[srv.port]]
    num = 80
    [srv.meta]
    note = "n"
    """)
    // [[srv.port]] appends under srv[last]; [srv.meta] reopens srv[last] too.
    #expect(r.headerSpans[[.key("srv"), .index(0), .key("port"), .index(0)]] ==
            Toml.SourceSpan(line: 3, column: 1))
    #expect(r.headerSpans[[.key("srv"), .index(0), .key("meta")]] ==
            Toml.SourceSpan(line: 5, column: 1))
    #expect(r.entrySpans[[.key("srv"), .index(0), .key("port"), .index(0), .key("num")]]?.value ==
            Toml.SourceSpan(line: 4, column: 7))
    #expect(r.entrySpans[[.key("srv"), .index(0), .key("meta"), .key("note")]]?.value ==
            Toml.SourceSpan(line: 6, column: 8))
}

@Test func multilineArrayValueSpanAtOpenBracket() throws {
    let r = try Toml.parseWithSpans("""
    xs = [
      1,
      2,
    ]
    after = true
    """)
    #expect(r.tree["xs"]?.asArray == [.int(1), .int(2)])
    #expect(r.entrySpans[[.key("xs")]]?.value == Toml.SourceSpan(line: 1, column: 6))
    // The entry after the multi-line value is attributed to its real line.
    #expect(r.entrySpans[[.key("after")]]?.value == Toml.SourceSpan(line: 5, column: 9))
}

@Test func inlineTableSpansOnlyTheEntry() throws {
    let r = try Toml.parseWithSpans("m = { a = 1 }")
    #expect(r.tree["m"]?.asTable?["a"]?.asInt == 1)
    #expect(r.entrySpans[[.key("m")]]?.value == Toml.SourceSpan(line: 1, column: 5))
    // Inline-table interiors are not indexed — the entry is the unit.
    #expect(r.entrySpans[[.key("m"), .key("a")]] == nil)
}

@Test func lastWriteWinsSpanFollowsSurvivingValue() throws {
    let r = try Toml.parseWithSpans("k = 1\nk = 2")
    #expect(r.tree["k"]?.asInt == 2)
    #expect(r.entrySpans[[.key("k")]]?.value == Toml.SourceSpan(line: 2, column: 5))
}

@Test func bomDoesNotShiftSpans() throws {
    let r = try Toml.parseWithSpans("\u{FEFF}k = 1")
    #expect(r.tree["k"]?.asInt == 1)
    #expect(r.entrySpans[[.key("k")]] ==
            Toml.EntrySpans(key: .init(line: 1, column: 1), value: .init(line: 1, column: 5)))
}

@Test func crlfDocumentSpansCountPhysicalLines() throws {
    // The deliberate delta from the line-based `parse`: CRLF documents parse
    // (and attribute correctly) here, while `parse`'s Character-based
    // `split(separator: "\n")` folds the whole document into one line and
    // throws. Pin BOTH sides so the delta stays visible and intentional.
    let src = "a = 1\r\n[t]\r\nb = 2\r\n"
    let r = try Toml.parseWithSpans(src)
    #expect(r.tree["a"]?.asInt == 1)
    #expect(r.tree["t"]?.asTable?["b"]?.asInt == 2)
    #expect(r.entrySpans[[.key("t"), .key("b")]]?.value == Toml.SourceSpan(line: 3, column: 5))
    #expect(throws: Toml.ParseError.self) { try Toml.parse(src) }
}

@Test func crlfMultilineArrayParsesAndAttributes() throws {
    // A CRLF document whose VALUE spans lines: the fold must normalize the
    // array's interior "\r\n" before the decode (decodeScalar re-joins lines
    // through parseFlat, whose Character-based split can't see CRLF).
    let src = "xs = [\r\n  1,\r\n  2,\r\n]\r\nafter = true\r\n"
    let r = try Toml.parseWithSpans(src)
    #expect(r.tree["xs"]?.asArray == [.int(1), .int(2)])
    #expect(r.tree["after"]?.asBool == true)
    #expect(r.entrySpans[[.key("xs")]]?.value == Toml.SourceSpan(line: 1, column: 6))
    #expect(r.entrySpans[[.key("after")]]?.value == Toml.SourceSpan(line: 5, column: 9))
}

@Test func tilerStrictnessDeltasArePinned() throws {
    // The other deliberate delta class: invalid TOML the old line scanner
    // silently tolerated now throws (the tiler is conformance-grade). Pin one
    // example per rule so the equivalence contract's exceptions stay explicit.
    // 1. a raw control char in a comment (lexValidateComment)
    let ctl = "k = 1 # a\u{0001}b\n"
    #expect((try Toml.parse(ctl))["k"]?.asInt == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(ctl) }
    // 2. the degenerate empty header (lexDottedPathStrict: empty key)
    let empty = "[]\nx = 1\n"
    #expect((try Toml.parse(empty))[""]?.asTable?["x"]?.asInt == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(empty) }
}

@Test func tabIndentedEntryColumns() throws {
    // Columns are 1-based Unicode-scalar offsets: a tab counts as ONE column,
    // matching the header rule leadingColumn established for Row.span.
    let r = try Toml.parseWithSpans("[t]\n\tk = 'v'\n")
    #expect(r.entrySpans[[.key("t"), .key("k")]] ==
            Toml.EntrySpans(key: .init(line: 2, column: 2), value: .init(line: 2, column: 6)))
}

@Test func spannedKeyEscapesStayLiteralLikeLossyParse() throws {
    // The pinned lossy-projection contract (see lossyKeyEscapesStayLiteral):
    // quoted keys keep their escapes LITERAL. The derivation re-lexes keys
    // from the raw spelling with the lossy finisher, so `"a\tb"` stays the
    // backslash-t key here too — NOT the DOM's escape-decoded form.
    let r = try Toml.parseWithSpans(#"""
    ["a\tb"]
    x = 1
    """#)
    #expect(r.tree[#"a\tb"#]?.asTable?["x"]?.asInt == 1)
    #expect(r.tree["a\tb"] == nil)
    #expect(r.entrySpans[[.key(#"a\tb"#), .key("x")]]?.value == Toml.SourceSpan(line: 2, column: 5))
}

// MARK: - Equivalence with the line-based strict parse (the unification gate)

/// Both succeed with the SAME tree (Row.spans included), or both throw.
private func expectEquivalent(_ source: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
    let legacy = Result { try Toml.parse(source) }
    let derived = Result { try Toml.parseWithSpans(source) }
    switch (legacy, derived) {
    case let (.success(a), .success(b)):
        #expect(b.tree == a, "tree diverged for:\n\(source)", sourceLocation: sourceLocation)
    case (.failure, .failure):
        break
    case let (.success(a), .failure(e)):
        Issue.record("derived threw where legacy parsed: \(e)\n\(source)\nlegacy: \(a)",
                     sourceLocation: sourceLocation)
    case let (.failure(e), .success(b)):
        Issue.record("derived parsed where legacy threw: \(e)\n\(source)\nderived: \(b.tree)",
                     sourceLocation: sourceLocation)
    }
}

@Test func equivalenceOnHandCorpus() {
    let corpus: [String] = [
        "",                                          // empty document
        "# only a comment\n",
        "k = 1",                                     // no trailing newline
        "top = 1\n[a]\nx = \"hi\"\n[a.b]\ny = true\nc.d.e = 2\n",
        "[behavior.\"com.apple.Safari\"]\nroles = [\"Link\"]\n",
        "m = { a = 1, \"q.k\" = \"v\", flag = false }\n",
        "[[bindings]]\ninput = \"a\"\n\n[[bindings]]\ninput = \"b\"\n  [[bindings.per-app]]\n  bundle-id = \"com.x\"\n",
        "[[a]]\nx = 1\n[a]\ny = 2\n",                // std header reopens the AoT's last row
        "[[a.b]]\nn = 1\n[[a.b]]\nn = 2\n",          // nested AoT append
        "a = 1\n[a.b]\nc = 2\n",                     // scalar overwritten by a table
        "k = 1\nk = 2\n",                            // duplicate key, last write wins
        "empty = []\ntrail = [\"x\", \"y\",]\n",
        "xs = [\n  \"a, \\\"b\\\"\",  # comment inside\n  \"c\",\n]\nafter = 1\n",
        "white = 0xFFFFFF\nwhole = 2\nfrac = 1.5\nexp = 1e3\n",
        "lit = 'raw \\n stays'\nunknown = \"x\\qy\"\n",
        "say = \"echo \\\"hi\\\"\"   # greet\n",
        "url = \"https://x/#frag\"   # trailing comment\n",
        "\t[tab]\n\tk = 'v'\n",                      // tab-indented header + entry
        "9 = \"numeric bare key\"\n[10]\nx = 1\n",
        #"["a\tb"]"# + "\nx = 1\n",                  // escape-literal quoted key
        "s = \"\"\"one line\"\"\"\n",                // garbage-tolerated single-line triple quote
        // Rejected by both (M1 grammar / structure):
        "d = 1979-05-27T07:32:00Z\n",                // datetime: outside the M1 grammar
        "s = \"\"\"\nreal multi-line\n\"\"\"\n",     // multi-line string
        "t = {\n a = 1 }\n",                         // multi-line inline table
        "k =\n",                                     // empty value
        "k = # only a comment\n",
        "color = red\n",                             // unrecognised scalar
        "x 1\n",                                     // missing '='
        "[a\nx = 1\n",                               // unterminated header
        "arr = [1, 2\n",                             // unterminated array (EOF)
    ]
    for source in corpus { expectEquivalent(source) }
}

private func fixture(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"),
        "missing fixture \(name).toml"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

@Test(arguments: ["chord.config", "facet.config", "facet.sections",
                  "halo.config", "perch.config", "wand.config", "still"])
func equivalenceOnRealConfigs(_ name: String) throws {
    expectEquivalent(try fixture(name))
}

@Test func chordRealConfigParsesWithSpans() throws {
    // The consumer this exists for: chord's real config must parse with the
    // same tree AND carry a span for every one of its assignments (the fixture
    // has root entries + [options]; [[bindings]] shapes are covered above and
    // in the hand corpus).
    let source = try fixture("chord.config")
    let r = try Toml.parseWithSpans(source)
    #expect(r.tree == (try Toml.parse(source)))
    let opts = try #require(r.tree["options"]?.asTable)
    #expect(!opts.isEmpty)
    for key in opts.keys {
        let span = try #require(r.entrySpans[[.key("options"), .key(key)]],
                                "no span for [options].\(key)")
        #expect(span.value.line == span.key.line)
        #expect((span.value.column ?? 0) > (span.key.column ?? 0))
    }
    #expect(r.headerSpans[[.key("options")]] != nil)
}

@Test func equivalenceOnFuzzCorpus() {
    // The shared fuzz grammar, LF-normalized (the CRLF delta is pinned in
    // crlfDocumentSpansCountPhysicalLines — Character-based split can't see
    // CRLF, so legacy would throw on every CRLF document).
    var r = TomlFuzzGen.SplitMix64(seed: 0xC0FFEE_D0_0D)
    var bothParsed = 0
    for i in 0..<2000 {
        var s = TomlFuzzGen.document(&r).replacingOccurrences(of: "\r\n", with: "\n")
        // The grammar never reuses a section name, so multi-row arrays-of-
        // tables (Row.span beyond index 0, last-element drilling) would go
        // unfuzzed: graft a repeated-AoT coda onto every fourth document.
        if i % 4 == 0 { s += "\n[[dup]]\nn = 1\n[[dup]]\nn = 2\n" }
        expectEquivalent(s)
        if (try? Toml.parse(s)) != nil { bothParsed += 1 }
    }
    // Keep the property meaningful: a healthy share of generated documents
    // must exercise the both-succeed arm, not just both-throw.
    #expect(bothParsed > 400, "fuzz corpus degenerated: only \(bothParsed)/2000 parsed")
}
