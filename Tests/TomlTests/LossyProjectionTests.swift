import Testing
import Foundation
@testable import Toml

// Behavioral contract of the LOSSY read projection (`parse` / `parseFlat` /
// `Value` / `Document` / `lineKey` / accessors) — ported from sill's
// `TomlTests` so the five consumers see byte-identical behavior after the
// swap. This locks what the projection MUST preserve; it is independent of
// the lossless `Annotated` round-trip (covered in RoundTripTests).

// MARK: - Value model

@Test func valueEquatable() {
    #expect(Toml.Value.int(1) == .int(1))
    #expect(Toml.Value.int(1) != .double(1))
    #expect(Toml.Value.array([.string("a"), .int(2)]) == .array([.string("a"), .int(2)]))
    #expect(Toml.Value.arrayOfTables([["k": .bool(true)]]) == .arrayOfTables([["k": .bool(true)]]))
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
    // dotted key c.d.e collapses to nested tables
    #expect(root["a"]?.asTable?["b"]?.asTable?["c"]?.asTable?["d"]?.asTable?["e"]?.asInt == 2)
}

@Test func inlineTableNested() throws {
    let root = try Toml.parse(#"m = { a = 1, "q.k" = "v", flag = false }"#)
    let t = try #require(root["m"]?.asTable)
    #expect(t["a"]?.asInt == 1)
    #expect(t["q.k"]?.asString == "v")       // quoted inline-table key
    #expect(t["flag"]?.asBool == false)
}

@Test func quotedDottedHeaderKeepsInteriorDots() throws {
    // [behavior."com.apple.Safari"] must NOT split the bundle id.
    let root = try Toml.parse(#"""
    [behavior."com.apple.Safari"]
    roles = ["Link"]
    """#)
    let inner = try #require(root["behavior"]?.asTable?["com.apple.Safari"]?.asTable)
    #expect(inner["roles"]?.asStringArray == ["Link"])
}

@Test func nestedArrayOfTablesDrillAndLineKey() throws {
    let root = try Toml.parse("""
    [[server]]
    name = "alpha"
    [[server.port]]
    num = 80
    """)
    let rows = try #require(root["server"]?.asArrayOfTables)
    #expect(rows.count == 1)
    #expect(rows[0]["name"]?.asString == "alpha")
    #expect(rows[0][Toml.lineKey]?.asInt == 1)     // [[server]] on line 1
    let ports = try #require(rows[0]["port"]?.asArrayOfTables)
    #expect(ports.count == 1)
    #expect(ports[0]["num"]?.asInt == 80)
    #expect(ports[0][Toml.lineKey]?.asInt == 3)    // [[server.port]] on line 3
}

@Test func strictThrowsOnUnrecognisedScalar() {
    let err = #expect(throws: Toml.ParseError.self) { try Toml.parse("color = red") }
    #expect(err?.line == 1)
    #expect(err?.message.contains("unrecognised") == true)
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
    // headers stay LITERAL (dotted text), not nested
    #expect(doc.tables["cast"]?["button"]?.asString == "right")
    #expect(doc.tables["cast.overlay.trail"]?["width"]?.asInt == 3)
    #expect(doc.tables["cast.overlay.trail"]?["color"]?.asString == "#3b82f6")
    #expect(doc.tables["cast"]?["overlay.trail"] == nil)   // not folded into cast
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
    // a plain [section] closes the AoT; no __line__ in flat rows
    #expect(rows[0][Toml.lineKey] == nil)
    #expect(doc.tables["other"]?["z"]?.asInt == 1)
}

@Test func lenientDropsBadLineKeepsRest() {
    let doc = Toml.parseFlat("""
    [s]
    good = 1
    bad = red
    also-good = "yes"
    """)
    #expect(doc.tables["s"]?["good"]?.asInt == 1)
    #expect(doc.tables["s"]?["bad"] == nil)               // unrecognised → dropped
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
    #expect(doc.tables["n"]?["whole"] == .int(2))   // bare int stays int
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

/// An escaped quote `\"` inside a BASIC string must not close it, so a `#`
/// that follows the real closing quote is the comment — not swallowed as
/// string interior (which would drop the whole binding).
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

// MARK: - Multi-line arrays (the Phase 1.6 superset delta + perch bug fix)

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
    // the key AFTER the multi-line array still parses
    #expect(doc.tables["behavior"]?["min-size"]?.asInt == 6)
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

@Test func chordRealConfigParsesStrict() throws {
    let root = try Toml.parse(try fixture("chord.config"))
    // [options] is a nested table with real keys
    let opts = try #require(root["options"]?.asTable)
    #expect(opts["passthrough-unmatched"]?.asBool == true)
    #expect(opts["exclude-apps"]?.asArray != nil)
}

@Test func facetRealConfigParsesFlat() throws {
    let doc = Toml.parseFlat(try fixture("facet.config"))
    #expect(doc.tables["theme"]?["name"]?.asString == "terminal")
    #expect(doc.tables["grid"]?["cols"]?.asInt == 5)
    // [[exclude]] array-of-tables
    #expect((doc.arrays["exclude"]?.count ?? 0) >= 3)
    #expect(doc.arrays["exclude"]?.first?["app"]?.asString == "com.apple.systempreferences")
    // inline table value under a dotted [desktop.1] section
    #expect(doc.tables["desktop.1"]?["1"]?.asTable?["name"]?.asString == "Dev")
}

@Test func wandRealConfigParsesFlat() throws {
    let doc = Toml.parseFlat(try fixture("wand.config"))
    #expect(doc.tables["cast.overlay.trail"]?["color"]?.asString == "#3b82f6")
    #expect(doc.tables["cast.overlay.trail"]?["width"]?.asInt == 3)
    // [[...]] AoT keyed by literal dotted name
    #expect((doc.arrays["cast.cursor.rule"] ?? doc.arrays["tome.cursor.item"]) != nil)
}

@Test func perchRealConfigParsesFlat() throws {
    let doc = Toml.parseFlat(try fixture("perch.config"))
    #expect(doc.tables["hotkey"]?["active"]?.asString == "shift+space")
    #expect(doc.tables["overlay.sound"]?["volume"]?.asDouble == 0.5)
}

/// The Phase 1.6 fix: perch ships a MULTI-LINE `roles` array that the old
/// single-line parsers silently dropped. The shared parser now reads it.
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
