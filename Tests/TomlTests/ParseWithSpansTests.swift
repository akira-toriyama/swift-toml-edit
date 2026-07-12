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
//      • CRLF terminators: the line-based `parse` never actually split CRLF
//        (a Swift `Character` folds "\r\n", so `split(separator: "\n")` sees
//        one line and, for a multi-entry document, throws); the DOM
//        derivation handles CRLF correctly —
//        crlfDocumentSpansCountPhysicalLines. Reverse arm: a raw CRLF
//        *inside* a single-line string survives legacy's one-line fold as
//        garbage content, the derivation throws — crlfInsideStringPinned.
//      • triple-quoted spellings: any `"""`/`'''` string spelling in a value
//        throws in the derivation (out of the M1 grammar, and past a triple
//        quote the two quote models disagree) — where legacy garbage-parses,
//        wrongly throws, or would trick a lenient replay into dropping keys —
//        outOfGrammarQuoteSpellingsPinned.
//      • tiler strictness: invalid TOML the old scanner silently tolerated
//        (a control char in a comment, a degenerate `[]` header, an invalid
//        bare key) now throws — tilerStrictnessDeltasArePinned.
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
    // (`try` stays out of #expect operands — Swift 6.0's macro expansion
    // wraps them in non-throwing autoclosures.)
    // 1. a raw control char in a comment (lexValidateComment)
    let ctl = "k = 1 # a\u{0001}b\n"
    let legacyCtl = try Toml.parse(ctl)
    #expect(legacyCtl["k"]?.asInt == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(ctl) }
    // 2. the degenerate empty header (lexDottedPathStrict: empty key)
    let empty = "[]\nx = 1\n"
    let legacyEmpty = try Toml.parse(empty)
    #expect(legacyEmpty[""]?.asTable?["x"]?.asInt == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(empty) }
    // 3. an invalid bare key (lexDottedPathStrict: bare-key charset)
    let bare = "[foo bar]\nx = 1\n"
    let legacyBare = try Toml.parse(bare)
    #expect(legacyBare["foo bar"]?.asTable?["x"]?.asInt == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(bare) }
}

@Test func loneCRValuesStayEquivalent() throws {
    // A LONE raw CR (not part of a CRLF) inside a single-line value is
    // invalid TOML that the legacy scanners tolerate; the fold's multi-line
    // test is "\n" ONLY, so these flow to the shared grammar and stay
    // equivalent rather than becoming an accidental delta.
    expectEquivalent("k = \"a\rb\"\n")
    expectEquivalent("k = 'a\rb'\n")
    expectEquivalent("m = { a = \"x\ry\" }\n")
    expectEquivalent("k = 1\r")                       // trailing lone CR at EOF
    expectEquivalent("xs = [\"a\rb\"]\n")
    let r = try Toml.parseWithSpans("k = \"a\rb\"\n")
    #expect(r.tree["k"] == .string("a\rb"))
}

@Test func outOfGrammarQuoteSpellingsPinned() throws {
    // Triple-quoted spellings are out of the M1 grammar and the boundary
    // where the legacy naive quote model and the lex model disagree. The
    // derivation THROWS on all of them; legacy variously garbage-parses or
    // wrongly throws. Pinning each keeps the delta deliberate — and proves
    // none of them can silently drop keys anymore.
    // a) single-line triple quote: legacy garbage-parses.
    let single = "s = \"\"\"one line\"\"\"\n"
    let legacySingle = try Toml.parse(single)
    #expect(legacySingle["s"] == .string("\"\"one line\"\""))
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(single) }
    // b) quote-run-4 + comment parity: legacy keeps "#junk\"" as string body.
    let parity = "a = \"\"\"\"x\"\"\" #junk\"\n"
    let legacyParity = try Toml.parse(parity)
    #expect(legacyParity["a"] == .string("\"\"\"x\"\"\" #junk"))
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(parity) }
    // c) the over-consumption trap: the tiler sees an OPEN multi-line string
    //    and swallows the next line — the fold must throw, never silently
    //    return {a} while legacy returns {a, b}.
    let swallow = "a = [ \"\"\"\"]\nb = 1\n"
    let legacySwallow = try Toml.parse(swallow)
    #expect(legacySwallow["b"]?.asInt == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(swallow) }
    // d) same trap with a header coda: the [[t]] row must not vanish.
    let swallowHeader = "a = [ \"\"\"\"]\n[[t]]\nn = 7\n"
    let legacyHeader = try Toml.parse(swallowHeader)
    #expect(legacyHeader["t"]?.asArrayOfTables?.count == 1)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(swallowHeader) }
    // e) valid TOML that legacy WRONGLY throws on (its quote parity leaves
    //    the `]` inside a phantom string): both throw now — equivalent.
    expectEquivalent("a = [ \"\"\"\"x\"\"\" ]\nb = \"y\"\n")
    // f) CRLF inside a multi-line string inside an array: legacy's one-line
    //    fold garbage-keeps the CRLF; a lenient replay would space-join it.
    let crlfString = "xs = [\"\"\"a\r\nb\"\"\"]\n"
    let legacyCrlf = try Toml.parse(crlfString)
    #expect(legacyCrlf["xs"] != nil)
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(crlfString) }
}

@Test func crlfInsideStringPinned() throws {
    // The CRLF delta's REVERSE arm: raw CRLF *inside* single-line string
    // content. Legacy's Character-fold never splits it, so the whole document
    // stays one parseable line and the CRLF survives as garbage string
    // content; the tiler splits it into an unterminated string → throw.
    let quoted = "k = \"a\r\nb\"\n"
    let legacyQuoted = try Toml.parse(quoted)
    #expect(legacyQuoted["k"] == .string("a\r\nb"))
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(quoted) }
    // Same content inside a CRLF multi-line array: legacy happens to throw
    // too (splitCommaSeparated keeps the raw CR in the element), and the
    // derivation's string-aware normalization refuses to rewrite string
    // interiors — both throw, and neither may silently space-join content.
    let inArray = "xs = [\r\n\"a\r\nb\",\r\n]\r\n"
    #expect(throws: Toml.ParseError.self) { try Toml.parse(inArray) }
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(inArray) }
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
    // `try` hoisted out of #expect: Swift 6.0's macro expansion wraps the
    // operand in a non-throwing autoclosure (the Linux job's toolchain).
    let expected = try Toml.parse(source)
    #expect(r.tree == expected)
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
    // crlfDocumentSpansCountPhysicalLines / crlfInsideStringPinned —
    // Character-based split can't see CRLF, so a multi-entry CRLF document
    // throws in legacy unless its CRLFs hide inside quoted string content).
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
