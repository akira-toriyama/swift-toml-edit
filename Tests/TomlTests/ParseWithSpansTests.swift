import Testing
import Foundation
@testable import Toml

// `parseWithSpans` — the DOM-derived lossy parse (chord#159 / t-0030), and,
// since the line-based strict scanner retired (v3), the ONE engine behind
// `Toml.parse` (which returns this fold's `.tree`).
//
// Locked here:
//
// 1. SPANS: per-entry key/value locations and per-header locations, exact to
//    the line AND column — the capability chord's column-precise warnings
//    need (`(config.toml:N:C)`).
//
// 2. The UNIFIED strict-parse behavior at every point where the retired line
//    scanner deliberately diverged (each was a pinned equivalence delta while
//    both implementations coexisted; the tiler's side is now the contract):
//      • CRLF documents parse and attribute correctly (the scanner's
//        Character-based `split(separator: "\n")` folded "\r\n" and threw) —
//        crlfDocumentSpansCountPhysicalLines. Reverse arm: a raw CRLF
//        *inside* single-line string content throws (the scanner kept it as
//        garbage content) — crlfInsideStringThrows.
//      • triple-quoted spellings: any `"""`/`'''` string spelling in a value
//        throws (out of the M1 grammar, and past a triple quote rejecting is
//        the only contract that cannot silently drop keys) —
//        outOfGrammarQuoteSpellingsThrow.
//      • tiler strictness: invalid TOML the old scanner silently tolerated
//        (a control char in a comment, a degenerate `[]` header, an invalid
//        bare key) throws — tilerStrictnessAppliesToParse.
//
// 3. CORPUS: the unification gate's hand corpus, the family's real configs
//    and the shared fuzz grammar keep exercising the fold end-to-end — as
//    OUTCOME pins now, not equivalence (there is no second implementation
//    left to compare against).

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

// MARK: - The unified strict-parse behavior (the retired scanner's deltas)

@Test func crlfDocumentSpansCountPhysicalLines() throws {
    // CRLF documents parse and attribute to physical lines — the scalar-based
    // lexLines splits "\r\n" properly. (The retired line scanner never could:
    // a Swift `Character` folds CRLF, so it saw a one-line document and, for
    // any multi-entry document, threw.)
    let src = "a = 1\r\n[t]\r\nb = 2\r\n"
    let r = try Toml.parseWithSpans(src)
    #expect(r.tree["a"]?.asInt == 1)
    #expect(r.tree["t"]?.asTable?["b"]?.asInt == 2)
    #expect(r.entrySpans[[.key("t"), .key("b")]]?.value == Toml.SourceSpan(line: 3, column: 5))
    // `parse` delegates to the same fold — identical tree, no CRLF quirk.
    let p = try Toml.parse(src)
    #expect(p == r.tree)
}

@Test func crlfMultilineArrayParsesAndAttributes() throws {
    // A CRLF document whose VALUE spans lines: the fold normalizes the array's
    // interior "\r\n" before the decode. That normalization is LOAD-BEARING, not
    // a leftover — it is the strict path's only CR filter, and parseFlat reading
    // CRLF correctly does not replace it (see normalizedMultilineArrayValue).
    let src = "xs = [\r\n  1,\r\n  2,\r\n]\r\nafter = true\r\n"
    let r = try Toml.parseWithSpans(src)
    #expect(r.tree["xs"]?.asArray == [.int(1), .int(2)])
    #expect(r.tree["after"]?.asBool == true)
    #expect(r.entrySpans[[.key("xs")]]?.value == Toml.SourceSpan(line: 1, column: 6))
    #expect(r.entrySpans[[.key("after")]]?.value == Toml.SourceSpan(line: 5, column: 9))
}

@Test func tilerStrictnessAppliesToParse() {
    // Invalid TOML the retired line scanner silently tolerated throws in the
    // unified `parse` (the tiler is conformance-grade) — one example per rule.
    // 1. a raw control char in a comment (lexValidateComment)
    #expect(throws: Toml.ParseError.self) { try Toml.parse("k = 1 # a\u{0001}b\n") }
    // 2. the degenerate empty header (lexDottedPathStrict: empty key)
    #expect(throws: Toml.ParseError.self) { try Toml.parse("[]\nx = 1\n") }
    // 3. an invalid bare key (lexDottedPathStrict: bare-key charset)
    #expect(throws: Toml.ParseError.self) { try Toml.parse("[foo bar]\nx = 1\n") }
}

@Test func loneCRValuesStillParse() throws {
    // A LONE raw CR (not part of a CRLF) inside a single-line value is
    // invalid TOML the shared scalar grammar tolerates; the fold's multi-line
    // test is "\n" ONLY, so these flow through unchanged (never rewritten,
    // never split).
    let basic = try Toml.parse("k = \"a\rb\"\n")
    #expect(basic["k"] == .string("a\rb"))
    let literal = try Toml.parse("k = 'a\rb'\n")
    #expect(literal["k"] == .string("a\rb"))
    let inline = try Toml.parse("m = { a = \"x\ry\" }\n")
    #expect(inline["m"]?.asTable?["a"] == .string("x\ry"))
    let eof = try Toml.parse("k = 1\r")            // trailing lone CR at EOF
    #expect(eof["k"]?.asInt == 1)
    let arr = try Toml.parse("xs = [\"a\rb\"]\n")
    #expect(arr["xs"] == .array([.string("a\rb")]))
}

@Test func outOfGrammarQuoteSpellingsThrow() {
    // Triple-quoted spellings are out of the M1 grammar and the boundary
    // where naive quote models go wrong: past a triple quote, tolerating
    // means either garbage content or silently dropped keys (the tiler sees
    // an OPEN multi-line string and would swallow the next line/header).
    // The fold throws on ALL of them — no spelling may parse partially.
    let spellings: [String] = [
        "s = \"\"\"one line\"\"\"\n",              // single-line triple quote
        "a = \"\"\"\"x\"\"\" #junk\"\n",           // quote-run-4 + comment parity
        "a = [ \"\"\"\"]\nb = 1\n",                // over-consumption: next entry
        "a = [ \"\"\"\"]\n[[t]]\nn = 7\n",         // over-consumption: header coda
        "a = [ \"\"\"\"x\"\"\" ]\nb = \"y\"\n",    // valid TOML, still out of M1
        "xs = [\"\"\"a\r\nb\"\"\"]\n",             // CRLF inside a multi-line string
    ]
    for s in spellings {
        #expect(throws: Toml.ParseError.self, "parse should reject:\n\(s)") {
            try Toml.parse(s)
        }
        #expect(throws: Toml.ParseError.self, "parseWithSpans should reject:\n\(s)") {
            try Toml.parseWithSpans(s)
        }
    }
}

@Test func crlfInsideStringThrows() {
    // Raw CRLF *inside* single-line string content: the tiler splits it into
    // an unterminated string → throw. (The retired scanner's one-line CRLF
    // fold kept it as garbage string content.) Neither spelling may silently
    // space-join or rewrite string interiors.
    #expect(throws: Toml.ParseError.self) { try Toml.parse("k = \"a\r\nb\"\n") }
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans("k = \"a\r\nb\"\n") }
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

// MARK: - Corpus (outcome pins — the retired unification gate's inputs)

@Test func handCorpusOutcomes() {
    // The unification gate's hand corpus, converted from equivalence checks
    // to outcome pins when the line scanner retired. First: documents that
    // must PARSE (the projection's supported surface).
    let parsing: [String] = [
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
    ]
    for source in parsing {
        do { _ = try Toml.parse(source) }
        catch { Issue.record("expected parse to accept:\n\(source)\nthrew: \(error)") }
    }
    // Second: documents that must THROW (M1 grammar / structure).
    let rejected: [String] = [
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
    for source in rejected {
        #expect(throws: Toml.ParseError.self, "expected parse to reject:\n\(source)") {
            try Toml.parse(source)
        }
    }
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
func realConfigsParseWithSpans(_ name: String) throws {
    // Every one of the family's real configs must ride the fold successfully.
    let r = try Toml.parseWithSpans(try fixture(name))
    #expect(!r.tree.isEmpty)
}

@Test func chordRealConfigParsesWithSpans() throws {
    // The consumer this exists for: chord's real config must carry a span for
    // every one of its assignments (the fixture has root entries + [options];
    // [[bindings]] shapes are covered above and in the hand corpus).
    let source = try fixture("chord.config")
    let r = try Toml.parseWithSpans(source)
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

@Test func fuzzCorpusRobustness() {
    // The shared fuzz grammar, LF-normalized (raw CRLF/CR behavior is pinned
    // above). With the line scanner retired there is no second implementation
    // to compare against; what the fuzz sweep still buys is (a) the fold
    // never crashes or over-consumes into a trap on any generated document,
    // and (b) the success arm stays healthy — the corpus keeps exercising
    // real parses, not just rejections.
    var r = TomlFuzzGen.SplitMix64(seed: 0xC0FFEE_D0_0D)
    var parsed = 0
    for i in 0..<2000 {
        var s = TomlFuzzGen.document(&r).replacingOccurrences(of: "\r\n", with: "\n")
        // The grammar never reuses a section name, so multi-row arrays-of-
        // tables (Row.span beyond index 0, last-element drilling) would go
        // unfuzzed: graft a repeated-AoT coda onto every fourth document.
        if i % 4 == 0 { s += "\n[[dup]]\nn = 1\n[[dup]]\nn = 2\n" }
        guard let t = try? Toml.parseWithSpans(s) else { continue }
        parsed += 1
        // Sanity on everything the fold reports: 1-based lines/columns.
        for (_, e) in t.entrySpans {
            if e.key.line < 1 || (e.key.column ?? 1) < 1 {
                Issue.record("bad entry span \(e) for:\n\(s)")
            }
        }
        for (_, h) in t.headerSpans where h.line < 1 {
            Issue.record("bad header span \(h) for:\n\(s)")
        }
    }
    #expect(parsed > 400, "fuzz corpus degenerated: only \(parsed)/2000 parsed")
}
