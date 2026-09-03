import Testing
import Foundation
@testable import Toml

// `parseWithSpans` — the ONE engine behind `Toml.parse`. Locked here:
//
// 1. SPANS: per-entry key/value locations and per-header locations, exact to
//    the line AND column — what chord's column-precise `(config.toml:N:C)`
//    warnings need.
//
// 2. The strict-parse contract (see the file head of ParseWithSpans.swift):
//    CRLF documents parse and attribute to physical lines, while a raw CRLF
//    inside single-line string content throws; every triple-quoted spelling
//    throws; the tiler's strictness (control char in a comment, `[]`
//    header, invalid bare key) applies to `parse`.
//
// 3. CORPUS: a hand corpus, the family's real configs and the shared fuzz
//    grammar exercise the fold end-to-end as outcome pins.

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
    #expect(r.tree["top"]?.asInt == 1)
    #expect(r.tree["server"]?.asTable?["host"]?.asString == "x")

    #expect(r.entrySpans[[.key("top")]] ==
            Toml.EntrySpans(key: .init(line: 1, column: 1), value: .init(line: 1, column: 7)))
    #expect(r.entrySpans[[.key("server"), .key("host")]] ==
            Toml.EntrySpans(key: .init(line: 3, column: 3), value: .init(line: 3, column: 10)))
    #expect(r.entrySpans[[.key("rule"), .index(0), .key("name")]] ==
            Toml.EntrySpans(key: .init(line: 5, column: 1), value: .init(line: 5, column: 8)))
    #expect(r.entrySpans[[.key("rule"), .index(1), .key("name")]] ==
            Toml.EntrySpans(key: .init(line: 7, column: 1), value: .init(line: 7, column: 8)))

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
    // Both `[[srv.port]]` and `[srv.meta]` bind under srv[last] (TOML 1.0).
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
    #expect(r.entrySpans[[.key("after")]]?.value == Toml.SourceSpan(line: 5, column: 9))
}

@Test func inlineTableSpansOnlyTheEntry() throws {
    let r = try Toml.parseWithSpans("m = { a = 1 }")
    #expect(r.tree["m"]?.asTable?["a"]?.asInt == 1)
    #expect(r.entrySpans[[.key("m")]]?.value == Toml.SourceSpan(line: 1, column: 5))
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

// MARK: - The strict-parse contract

@Test func crlfDocumentSpansCountPhysicalLines() throws {
    // A Swift `Character` folds CRLF, so any Character-based line split sees
    // a one-line document; the scalar-based `lexLines` must not.
    let src = "a = 1\r\n[t]\r\nb = 2\r\n"
    let r = try Toml.parseWithSpans(src)
    #expect(r.tree["a"]?.asInt == 1)
    #expect(r.tree["t"]?.asTable?["b"]?.asInt == 2)
    #expect(r.entrySpans[[.key("t"), .key("b")]]?.value == Toml.SourceSpan(line: 3, column: 5))
    let p = try Toml.parse(src)
    #expect(p == r.tree)
}

@Test func crlfMultilineArrayParsesAndAttributes() throws {
    // A CRLF document whose VALUE spans lines rides
    // `normalizedMultilineArrayValue`, the strict path's only CR filter.
    let src = "xs = [\r\n  1,\r\n  2,\r\n]\r\nafter = true\r\n"
    let r = try Toml.parseWithSpans(src)
    #expect(r.tree["xs"]?.asArray == [.int(1), .int(2)])
    #expect(r.tree["after"]?.asBool == true)
    #expect(r.entrySpans[[.key("xs")]]?.value == Toml.SourceSpan(line: 1, column: 6))
    #expect(r.entrySpans[[.key("after")]]?.value == Toml.SourceSpan(line: 5, column: 9))
}

@Test func tilerStrictnessAppliesToParse() {
    // One example per tiler rule.
    #expect(throws: Toml.ParseError.self) { try Toml.parse("k = 1 # a\u{0001}b\n") }   // lexValidateComment
    #expect(throws: Toml.ParseError.self) { try Toml.parse("[]\nx = 1\n") }            // lexDottedPathStrict: empty key
    #expect(throws: Toml.ParseError.self) { try Toml.parse("[foo bar]\nx = 1\n") }     // lexDottedPathStrict: bare-key charset
}

@Test func loneCRValuesStillParse() throws {
    // A LONE raw CR inside a single-line value is invalid TOML that the
    // lossy scalar grammar tolerates; the fold's multi-line test is "\n"
    // ONLY, so these flow through unchanged — never rewritten, never split.
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
    // Past a triple quote the naive quote model and the tiler disagree, so
    // tolerating means garbage content or silently dropped keys (the tiler
    // sees an OPEN multi-line string and swallows the next line / header).
    // No spelling may parse partially.
    let spellings: [String] = [
        "s = \"\"\"one line\"\"\"\n",              // single-line triple quote
        "a = \"\"\"\"x\"\"\" #junk\"\n",           // quote-run-4 + comment parity
        "a = [ \"\"\"\"]\nb = 1\n",                // over-consumption: next entry
        "a = [ \"\"\"\"]\n[[t]]\nn = 7\n",         // over-consumption: header coda
        "a = [ \"\"\"\"x\"\"\" ]\nb = \"y\"\n",    // valid TOML, still out of the lossy grammar
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
    // The tiler splits a raw CRLF inside single-line string content into an
    // unterminated string. Neither entry point may space-join or rewrite a
    // string interior to make it parse.
    #expect(throws: Toml.ParseError.self) { try Toml.parse("k = \"a\r\nb\"\n") }
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans("k = \"a\r\nb\"\n") }
    let inArray = "xs = [\r\n\"a\r\nb\",\r\n]\r\n"
    #expect(throws: Toml.ParseError.self) { try Toml.parse(inArray) }
    #expect(throws: Toml.ParseError.self) { try Toml.parseWithSpans(inArray) }
}

@Test func tabIndentedEntryColumns() throws {
    // Columns are Unicode-scalar offsets: a tab is ONE column, the same rule
    // `leadingColumn` applies to headers.
    let r = try Toml.parseWithSpans("[t]\n\tk = 'v'\n")
    #expect(r.entrySpans[[.key("t"), .key("k")]] ==
            Toml.EntrySpans(key: .init(line: 2, column: 2), value: .init(line: 2, column: 6)))
}

@Test func spannedKeyEscapesStayLiteralLikeLossyParse() throws {
    // The pinned lossy contract (see lossyKeyEscapesStayLiteral): the fold
    // must re-lex keys with the LOSSY finisher, not reuse the DOM's
    // escape-decoded `Block.path`.
    let r = try Toml.parseWithSpans(#"""
    ["a\tb"]
    x = 1
    """#)
    #expect(r.tree[#"a\tb"#]?.asTable?["x"]?.asInt == 1)
    #expect(r.tree["a\tb"] == nil)
    #expect(r.entrySpans[[.key(#"a\tb"#), .key("x")]]?.value == Toml.SourceSpan(line: 2, column: 5))
}

// MARK: - Corpus (outcome pins)

@Test func handCorpusOutcomes() {
    // Documents that must PARSE: the projection's supported surface.
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
    // Documents that must THROW: outside the lossy grammar, or malformed.
    let rejected: [String] = [
        "d = 1979-05-27T07:32:00Z\n",                // datetime: outside the lossy grammar
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
    let r = try Toml.parseWithSpans(try fixture(name))
    #expect(!r.tree.isEmpty)
}

@Test func chordRealConfigParsesWithSpans() throws {
    // The consumer this exists for: chord's real config must carry a span for
    // every one of its assignments.
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
    // above). What the sweep buys: the fold never crashes or over-consumes
    // into a trap on any generated document, and the success arm stays
    // healthy — the corpus keeps exercising real parses, not just rejections.
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
