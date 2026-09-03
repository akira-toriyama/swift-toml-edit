import Testing
import Foundation
@testable import Toml

// Behavioral contract of the LOSSY read projection (`parse` / `parseFlat` /
// `Value` / `Document` / `Row` + `SourceSpan` / accessors): what the five
// consumers depend on. Independent of the lossless `Annotated` round-trip
// (RoundTripTests).

// MARK: - Value model

@Test func valueEquatable() {
    #expect(Toml.Value.int(1) == .int(1))
    #expect(Toml.Value.int(1) != .double(1))
    #expect(Toml.Value.array([.string("a"), .int(2)]) == .array([.string("a"), .int(2)]))
    #expect(Toml.Value.arrayOfTables([Toml.Row(fields: ["k": .bool(true)])])
            == .arrayOfTables([Toml.Row(fields: ["k": .bool(true)])]))
}

@Test func accessors() {
    #expect(Toml.Value.string("x").asString == "x")
    #expect(Toml.Value.int(7).asInt == 7)
    #expect(Toml.Value.int(7).asInt64 == Int64(7))
    #expect(Toml.Value.double(1.5).asInt == nil)        // non-coercing
    #expect(Toml.Value.int(3).asDouble == 3.0)          // widening
    #expect(Toml.Value.double(1.5).asDouble == 1.5)
    #expect(Toml.Value.bool(false).asBool == false)
    #expect(Toml.Value.array([.string("a"), .int(2), .string("b")]).asStringArray == ["a", "b"])
}

// MARK: - Nested strict parse (chord)

@Test func nestedDottedKeysAndHeaders() throws {
    let root = try Toml.parse("""
    top = 1
    [a]
    x = "hi"
    [a.b]
    y = true
    c.d.e = 2
    """)
    #expect(root["top"]?.asInt == 1)
    #expect(root["a"]?.asTable?["x"]?.asString == "hi")
    #expect(root["a"]?.asTable?["b"]?.asTable?["y"]?.asBool == true)
    #expect(root["a"]?.asTable?["b"]?.asTable?["c"]?.asTable?["d"]?.asTable?["e"]?.asInt == 2)
}

@Test func inlineTableNested() throws {
    let root = try Toml.parse(#"m = { a = 1, "q.k" = "v", flag = false }"#)
    let t = try #require(root["m"]?.asTable)
    #expect(t["a"]?.asInt == 1)
    #expect(t["q.k"]?.asString == "v")
    #expect(t["flag"]?.asBool == false)
}

@Test func quotedDottedHeaderKeepsInteriorDots() throws {
    let root = try Toml.parse(#"""
    [behavior."com.apple.Safari"]
    roles = ["Link"]
    """#)
    let inner = try #require(root["behavior"]?.asTable?["com.apple.Safari"]?.asTable)
    #expect(inner["roles"]?.asStringArray == ["Link"])
}

@Test func lossyKeyEscapesStayLiteral() throws {
    // The lossy finisher (`unquoteKey`) strips the quote pair but does NOT
    // decode basic-string escapes: a `"a\tb"` key stays the LITERAL
    // backslash-t, never a tab. This pins the divergence from the lossless
    // DOM lookup (`lexDottedPath`, which decodes) — merging the two finishers
    // must fail here.
    let root = try Toml.parse(#"""
    ["a\tb"]
    x = 1
    """#)
    #expect(root[#"a\tb"#]?.asTable?["x"]?.asInt == 1)
    #expect(root["a\tb"] == nil)
}

@Test func nestedArrayOfTablesDrillAndSpan() throws {
    let root = try Toml.parse("""
    [[server]]
    name = "alpha"
    [[server.port]]
    num = 80
    """)
    let rows = try #require(root["server"]?.asArrayOfTables)
    #expect(rows.count == 1)
    #expect(rows[0]["name"]?.asString == "alpha")
    #expect(rows[0].span?.line == 1)
    #expect(rows[0].span?.column == 1)
    let ports = try #require(rows[0]["port"]?.asArrayOfTables)
    #expect(ports.count == 1)
    #expect(ports[0]["num"]?.asInt == 80)
    #expect(ports[0].span?.line == 3)
}

@Test func rowSpanPerElementAndColumn() throws {
    let root = try Toml.parse("""
    [[bindings]]
    input = "a"

    [[bindings]]
    input = "b"
      [[bindings.per-app]]
      bundle-id = "com.x"
    """)
    let rows = try #require(root["bindings"]?.asArrayOfTables)
    #expect(rows.count == 2)
    #expect(rows[0].span?.line == 1)
    #expect(rows[0].span?.column == 1)
    #expect(rows[1].span?.line == 4)
    // The nested `[[bindings.per-app]]` binds under the SECOND row (a[last].b).
    let perApp = try #require(rows[1]["per-app"]?.asArrayOfTables)
    #expect(perApp.count == 1)
    #expect(perApp[0].span?.line == 6)
    #expect(perApp[0].span?.column == 3)
    #expect(perApp[0]["bundle-id"]?.asString == "com.x")
    #expect(rows[0].fields.keys.sorted() == ["input"])   // no synthetic location key in the fields
}

@Test func handConstructedRowHasNilSpan() {
    // A synthesized desugar row has no source line; consumers rely on nil.
    let r = Toml.Row(fields: ["input": .string("a")])
    #expect(r.span == nil)
    #expect(r["input"]?.asString == "a")
}

@Test func strictThrowsOnUnrecognisedScalar() {
    // do/catch rather than the error-returning `#expect(throws:)` overload,
    // which is Swift 6.1-only; CI's Linux job runs 6.0.
    do {
        _ = try Toml.parse("color = red")
        Issue.record("expected parse to throw on an unrecognised scalar")
    } catch let e as Toml.ParseError {
        #expect(e.line == 1)
        #expect(e.message.contains("unrecognised"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
    #expect(throws: Toml.ParseError.self) { try Toml.parse("[a\nx = 1") }   // unterminated header
    #expect(throws: Toml.ParseError.self) { try Toml.parse("x 1") }          // missing '='
}

// MARK: - Flat lenient parse (facet / perch / wand)

@Test func flatLiteralHeaders() {
    let doc = Toml.parseFlat("""
    [cast]
    button = "right"
    [cast.overlay.trail]
    width = 3
    color = "#3b82f6"
    """)
    #expect(doc.tables["cast"]?["button"]?.asString == "right")
    #expect(doc.tables["cast.overlay.trail"]?["width"]?.asInt == 3)
    #expect(doc.tables["cast.overlay.trail"]?["color"]?.asString == "#3b82f6")
    #expect(doc.tables["cast"]?["overlay.trail"] == nil)
}

@Test func flatArrayOfTables() throws {
    let doc = Toml.parseFlat("""
    [[exclude]]
    app = "A"
    action = "float"
    [[exclude]]
    app = "B"
    [other]
    z = 1
    """)
    let rows = try #require(doc.arrays["exclude"])
    #expect(rows.count == 2)
    #expect(rows[0]["app"]?.asString == "A")
    #expect(rows[0]["action"]?.asString == "float")
    #expect(rows[1]["app"]?.asString == "B")
    #expect(rows[0]["__line__"] == nil)   // flat rows carry no synthetic location key
    #expect(rows[0].count == 2)
    #expect(doc.tables["other"]?["z"]?.asInt == 1)   // a plain [section] closes the AoT
}

@Test func lenientDropsBadLineKeepsRest() {
    let doc = Toml.parseFlat("""
    [s]
    good = 1
    bad = red
    also-good = "yes"
    """)
    #expect(doc.tables["s"]?["good"]?.asInt == 1)
    #expect(doc.tables["s"]?["bad"] == nil)
    #expect(doc.tables["s"]?["also-good"]?.asString == "yes")
}

@Test func hexInt() {
    let doc = Toml.parseFlat("""
    [c]
    white = 0xFFFFFF
    black = 0x000000
    """)
    #expect(doc.tables["c"]?["white"]?.asInt == 0xFFFFFF)
    #expect(doc.tables["c"]?["black"]?.asInt == 0)
}

@Test func intBeforeDouble() {
    let doc = Toml.parseFlat("""
    [n]
    whole = 2
    frac = 1.5
    exp = 1e3
    """)
    #expect(doc.tables["n"]?["whole"] == .int(2))
    #expect(doc.tables["n"]?["frac"] == .double(1.5))
    #expect(doc.tables["n"]?["exp"] == .double(1000))
}

@Test func quotesAndEscapes() {
    let doc = Toml.parseFlat(#"""
    [q]
    dq = "a\tb\nc\"d"
    literal = 'raw \n stays'
    unknown = "x\qy"
    """#)
    #expect(doc.tables["q"]?["dq"]?.asString == "a\tb\nc\"d")
    #expect(doc.tables["q"]?["literal"]?.asString == #"raw \n stays"#)
    #expect(doc.tables["q"]?["unknown"]?.asString == "xqy")  // \q → q
}

@Test func commentInsideQuotedStringPreserved() {
    let doc = Toml.parseFlat("""
    [c]
    url = "https://x/#frag"   # trailing comment stripped
    """)
    #expect(doc.tables["c"]?["url"]?.asString == "https://x/#frag")
}

// A `#` after an escaped `\"` must still be the comment; swallowing it as
// string interior would drop the whole binding.
@Test func escapedQuoteBeforeTrailingComment() {
    let doc = Toml.parseFlat(#"""
    [s]
    say = "echo \"hi\""   # greet
    plain = "no escapes"   # comment
    """#)
    #expect(doc.tables["s"]?["say"]?.asString == #"echo "hi""#)
    #expect(doc.tables["s"]?["plain"]?.asString == "no escapes")
}

@Test func escapedQuoteInsideArrayElement() {
    let doc = Toml.parseFlat(#"""
    [s]
    xs = ["a, \"b\"", "c"]   # two elements, not three
    """#)
    #expect(doc.tables["s"]?["xs"]?.asStringArray == [#"a, "b""#, "c"])
}

@Test func escapedQuoteInMultilineArray() {
    let doc = Toml.parseFlat(#"""
    [s]
    xs = [
        "plain",
        "with \"quote\" inside",
    ]
    after = 1
    """#)
    #expect(doc.tables["s"]?["xs"]?.asStringArray == ["plain", #"with "quote" inside"#])
    #expect(doc.tables["s"]?["after"]?.asInt == 1)
}

@Test func emptyAndTrailingCommaArrays() {
    let doc = Toml.parseFlat("""
    [a]
    empty = []
    trail = ["x", "y",]
    """)
    #expect(doc.tables["a"]?["empty"] == .array([]))
    #expect(doc.tables["a"]?["trail"]?.asStringArray == ["x", "y"])
}

// MARK: - CRLF line endings (parseFlat)

// A Swift `Character` folds "\r\n" into ONE grapheme, so a Character-based
// line split sees a whole CRLF document as a single line and leniently drops
// nearly all of it. The contract: a CRLF document reads exactly like its LF
// twin.

@Test func flatParsesCRLFDocument() throws {
    let doc = Toml.parseFlat("a = 1\r\nb = \"x\"\r\n[t]\r\nc = 3\r\n[[r]]\r\nname = \"n\"\r\n")
    #expect(doc.tables[""]?["a"]?.asInt == 1)
    #expect(doc.tables[""]?["b"]?.asString == "x")
    #expect(doc.tables["t"]?["c"]?.asInt == 3)
    let rows = try #require(doc.arrays["r"])
    #expect(rows.count == 1)
    #expect(rows[0]["name"]?.asString == "n")
}

/// The CRLF twin of an LF source. The naive replacement only builds a
/// faithful twin when the source holds no CR at all — an existing "\r\n"
/// would become "\r\r\n" — so a CR-bearing input is refused rather than
/// silently weakening the caller's assertion.
private func crlfTwin(of lf: String) throws -> String {
    try #require(!lf.contains("\r"),
                 "source already holds a CR — the naive twin-builder would corrupt it")
    return lf.replacingOccurrences(of: "\n", with: "\r\n")
}

@Test func flatCRLFDocumentEqualsLFTwin() throws {
    let lf = "a = 1\nb = \"x\"\n\n# banner\n[t]\nc = 3\nxs = [\n  \"p\",\n  \"q\",\n]\n\n[[r]]\nname = \"n\"\n[[r]]\nname = \"m\"\n"
    #expect(Toml.parseFlat(try crlfTwin(of: lf)) == Toml.parseFlat(lf))
}

@Test func flatCRLFMultilineArray() throws {
    let doc = Toml.parseFlat("xs = [\r\n  1,\r\n  2,\r\n]\r\nafter = true\r\n")
    #expect(doc.tables[""]?["xs"]?.asArray == [.int(1), .int(2)])
    #expect(doc.tables[""]?["after"]?.asBool == true)
}

// `Entry.value` rides `parseFlat` too, so it shares the CRLF contract.
@Test func annotatedEntryValueDecodesCRLFMultilineArray() throws {
    let dom = try Toml.Annotated(parsing: "xs = [\r\n  1,\r\n  2,\r\n]\r\n")
    #expect(dom.root.entry(forKey: "xs")?.value == .array([.int(1), .int(2)]))
}

// MARK: - Multi-line arrays

@Test func multilineArrayFlat() {
    let doc = Toml.parseFlat("""
    [behavior]
    roles = [
        "Button",
        "MenuItem",   # inline comment inside the array
        "Link",
    ]
    min-size = 6
    """)
    #expect(doc.tables["behavior"]?["roles"]?.asStringArray == ["Button", "MenuItem", "Link"])
    #expect(doc.tables["behavior"]?["min-size"]?.asInt == 6)   // the line cursor lands after the array
}

@Test func multilineArrayNested() throws {
    let root = try Toml.parse("""
    [opt]
    exclude = [
        "a.app",
        "b.app",
    ]
    """)
    #expect(root["opt"]?.asTable?["exclude"]?.asStringArray == ["a.app", "b.app"])
}

// MARK: - Real config golden corpus

private func fixture(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Fixtures"),
        "missing fixture \(name).toml"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

@Test(arguments: ["chord.config", "facet.config", "facet.sections",
                  "halo.config", "perch.config", "wand.config", "still"])
func realConfigsReadIdenticallyAsCRLF(_ name: String) throws {
    // The CRLF contract over the REAL corpus. It never bit a consumer only
    // because the family edits config on macOS, where editors write LF —
    // so no fixture exercises it by itself.
    let lf = try fixture(name)
    let doc = Toml.parseFlat(lf)
    let bindings = doc.tables.values.reduce(0) { $0 + $1.count }
        + doc.arrays.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
    #expect(bindings > 0, "fixture parsed to nothing — the CRLF comparison would be vacuous")
    #expect(Toml.parseFlat(try crlfTwin(of: lf)) == doc)
}

@Test func chordRealConfigParsesStrict() throws {
    let root = try Toml.parse(try fixture("chord.config"))
    let opts = try #require(root["options"]?.asTable)
    #expect(opts["passthrough-unmatched"]?.asBool == true)
    #expect(opts["exclude-apps"]?.asArray != nil)
}

@Test func facetRealConfigParsesFlat() throws {
    let doc = Toml.parseFlat(try fixture("facet.config"))
    #expect(doc.tables["theme"]?["name"]?.asString == "terminal")
    #expect(doc.tables["grid"]?["cols"]?.asInt == 5)
    #expect((doc.arrays["exclude"]?.count ?? 0) >= 3)
    #expect(doc.arrays["exclude"]?.first?["app"]?.asString == "com.apple.systempreferences")
    #expect(doc.arrays["desktop.1.section"]?.count == 2)
    #expect(doc.arrays["desktop.1.section"]?.first?["label"]?.asString == "Main")
    #expect(doc.arrays["desktop.1.section"]?.first?["layout"]?.asString == "bsp")
    #expect(doc.tables["desktop.2"]?["type"]?.asString == "isolate")
    #expect(doc.tables["desktop.2"]?["match"]?.asString
            == "app~=Chrome or app~=Safari or app~=Firefox")
    #expect(doc.tables["desktop.2"]?["show-non-matching"]?.asBool == true)
    // [alias] / [tags] / [[rule]] ship COMMENTED OUT in the vendored sample;
    // these two are a fixture-drift tripwire, not a parser check (a commented
    // header fails the `[` prefix test before comment-stripping is consulted).
    #expect(doc.tables["alias"] == nil)
    #expect(doc.tables["tags"] == nil)
    // The leak that CAN happen: a commented block's key lines landing in the
    // live table above them. `[config]` sits directly above the commented
    // `[tags]`, so it is where that pollution would surface.
    #expect(doc.tables["config"]?.count == 2)   // export-path + auto-promote
    #expect(doc.tables["config"]?.keys.contains { $0.hasPrefix("#") } == false)
}

@Test func wandRealConfigParsesFlat() throws {
    let doc = Toml.parseFlat(try fixture("wand.config"))
    #expect(doc.tables["cast.overlay.trail"]?["color"]?.asString == "#3b82f6")
    #expect(doc.tables["cast.overlay.trail"]?["width"]?.asInt == 3)
    #expect((doc.arrays["cast.cursor.rule"] ?? doc.arrays["tome.cursor.item"]) != nil)
}

@Test func perchRealConfigParsesFlat() throws {
    let doc = Toml.parseFlat(try fixture("perch.config"))
    #expect(doc.tables["hotkey"]?["active"]?.asString == "shift+space")
    #expect(doc.tables["overlay.sound"]?["volume"]?.asDouble == 0.5)
}

// perch ships a MULTI-LINE `roles` array; a single-line array reader would
// silently drop it.
@Test func perchMultilineRolesNowParses() throws {
    let doc = Toml.parseFlat(try fixture("perch.config"))
    let roles = try #require(
        doc.tables["behavior"]?["roles"]?.asStringArray,
        "perch [behavior].roles multi-line array did not parse"
    )
    #expect(roles.count == 11)
    #expect(roles.first == "Button")
    #expect(roles.last == "SearchField")
    #expect(roles.contains("SearchField"))
}
