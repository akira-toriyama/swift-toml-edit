import Testing
import Foundation
@testable import Toml

// Fast, corpus-independent coverage of the strict typed decoder (`decodeStrict`)
// + the redefinition machine (`typedTree`) + the tagged-JSON emitter. The
// authoritative gate is the official toml-test 1.0 conformance CI job (decoder:
// 205 valid / 474 invalid green); these tests give macOS-side coverage and pin
// the regression-prone corners (trailing-quote strings, int64 range, the four
// datetime tags, redefinition rejection, value-is-always-a-JSON-string).
@Suite struct DecodeStrictTests {

    private func v(_ s: String) throws -> Toml.TypedValue { try Toml.decodeStrict(s) }
    private func rejects(_ s: String, _ note: Comment? = nil,
                         _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note ?? "should reject \(s)", sourceLocation: loc) {
            _ = try Toml.decodeStrict(s)
        }
    }

    // MARK: strings

    @Test func basicEscapes() throws {
        #expect(try v(#""café""#) == .string("café"))
        #expect(try v(#""\U0001F600""#) == .string("😀"))
        #expect(try v(#""a\tb\r\n\"\\""#) == .string("a\tb\r\n\"\\"))
        #expect(try v(#""bell\bhere""#) == .string("bell\u{08}here"))
    }
    @Test func literalStringNoEscapes() throws {
        #expect(try v(#"'C:\Users\n'"#) == .string(#"C:\Users\n"#))
    }
    @Test func multilineLeadingNewlineTrimmed() throws {
        #expect(try v("\"\"\"\nhello\n\"\"\"") == .string("hello\n"))
        #expect(try v("'''\nraw\n'''") == .string("raw\n"))
    }
    @Test func multilineLineEndingBackslashFolds() throws {
        #expect(try v("\"\"\"a\\\n   b\"\"\"") == .string("ab"))
    }
    @Test func multilineTrailingQuotes() throws {
        // """"one quote"""" → "one quote" ; '''' '...'  trailing-quote rule.
        #expect(try v("\"\"\"\"one quote\"\"\"\"") == .string("\"one quote\""))
    }
    @Test func rejectReservedEscapesAndControls() {
        rejects(#""\q""#, "reserved escape")
        rejects(#""\x41""#, "\\x is not a TOML escape")
        rejects("\"raw\u{01}ctrl\"", "raw control char")
        rejects(#""\uD800""#, "surrogate is not a scalar")
    }

    // MARK: integers

    @Test func integerBasesAndUnderscores() throws {
        #expect(try v("1_000") == .integer(1000))
        #expect(try v("0xDEADbeef") == .integer(0xDEADBEEF))
        #expect(try v("0o755") == .integer(493))
        #expect(try v("0b1101_0110") == .integer(214))
        #expect(try v("-0") == .integer(0))
        #expect(try v("9223372036854775807") == .integer(.max))
        #expect(try v("-9223372036854775808") == .integer(.min))
    }
    @Test func rejectBadIntegers() {
        rejects("0123", "leading zero")
        rejects("0X1F", "uppercase prefix")
        rejects("-0xFF", "sign on radix int")
        rejects("1__0", "double underscore")
        rejects("_1", "leading underscore")
        rejects("1_", "trailing underscore")
        rejects("9223372036854775808", "overflow → must not silently become float")
    }

    // MARK: floats

    @Test func floats() throws {
        #expect(try v("3.14") == .float(3.14))
        #expect(try v("6.626e-34") == .float(6.626e-34))
        #expect(try v("224_617.445_991_228") == .float(224617.445991228))
        #expect(try v("inf") == .float(.infinity))
        #expect(try v("-inf") == .float(-.infinity))
        if case .float(let d) = try v("nan") { #expect(d.isNaN) } else { Issue.record("nan") }
    }
    @Test func rejectBadFloats() {
        rejects(".5", "leading dot")
        rejects("5.", "trailing dot")
        rejects("03.14", "leading zero in int part")
        rejects("Inf", "must be lowercase")
        rejects("1e", "empty exponent")
        rejects("1.0e1_", "trailing underscore in exponent")
    }

    // MARK: datetimes (the four distinct tags)

    @Test func datetimes() throws {
        #expect(try v("1979-05-27T07:32:00Z").jsonTag == "datetime")
        #expect(try v("1979-05-27T07:32:00-07:00").jsonTag == "datetime")
        #expect(try v("1979-05-27T07:32:00").jsonTag == "datetime-local")
        #expect(try v("1979-05-27 07:32:00").jsonTag == "datetime-local")   // space delimiter
        #expect(try v("1979-05-27").jsonTag == "date-local")
        #expect(try v("07:32:00").jsonTag == "time-local")
        #expect(try v("00:32:00.999999").jsonTag == "time-local")
    }
    @Test func rejectBadDatetimes() {
        rejects("1979-13-01", "month out of range")
        rejects("1979-02-30", "day out of range")
        rejects("2024-01-01T25:00:00", "hour out of range")
    }

    // MARK: composites

    @Test func heterogeneousAndNestedArrays() throws {
        #expect(try v("[1, 2.0, 'x', true]") == .array([.integer(1), .float(2.0), .string("x"), .boolean(true)]))
        #expect(try v("[[1,2],[3]]") == .array([.array([.integer(1), .integer(2)]), .array([.integer(3)])]))
    }
    @Test func inlineTableConflicts() {
        rejects("{ a.b = 1, a.b.c = 2 }", "extend a leaf")
        rejects("{ b = 1, b.c = 2 }", "extend a leaf")
        rejects("{ a = 1, a = 2 }", "duplicate key")
        rejects("{ a = 1, }", "trailing comma in inline table")
    }

    // MARK: redefinition machine (via typedTree)

    private func parses(_ s: String) throws -> Toml.TypedValue {
        try Toml.Annotated(parsing: s).typedTree()
    }
    private func docRejects(_ s: String, _ note: Comment? = nil,
                            _ loc: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, note, sourceLocation: loc) {
            _ = try Toml.Annotated(parsing: s).typedTree()
        }
    }

    @Test func redefinitionRejections() {
        docRejects("a = 1\na = 2\n", "duplicate key")
        docRejects("[t]\nx=1\n[t]\ny=2\n", "duplicate table")
        docRejects("a = 1\n[a.b]\nx = 2\n", "scalar then table")
        docRejects("[[f]]\nx=1\n[f]\ny=2\n", "table over array")
        docRejects("[a.b.c]\nz=9\n[a]\nb.c.t=1\n", "dotted key extends header table")
        docRejects("a.b = 0\na = {}\n", "redefine dotted table as inline")
    }
    @Test func redefinitionValidCases() throws {
        // Out-of-order + implicit-then-explicit is allowed exactly once.
        _ = try parses("[a.b.c]\nz=9\n[a]\nw=1\n")
        _ = try parses("a.b = 1\na.c = 2\n")        // sibling dotted keys extend `a`
        _ = try parses("[[f]]\nx=1\n[[f]]\ny=2\n")  // append array elements
    }

    // MARK: tagged JSON (value is ALWAYS a JSON string)

    @Test func taggedJsonShape() throws {
        #expect(try v("42").taggedJSON() == #"{"type":"integer","value":"42"}"#)
        #expect(try v("true").taggedJSON() == #"{"type":"bool","value":"true"}"#)
        #expect(try v("1979-05-27").taggedJSON() == #"{"type":"date-local","value":"1979-05-27"}"#)
        // A table with keys literally named type/value must NOT be confused with
        // a scalar; it stays a JSON object of tagged scalars.
        let t = try parses(#"type = "x""# + "\n" + #"value = 1"# + "\n")
        #expect(t.taggedJSON().contains(#""type":{"type":"string","value":"x"}"#))
    }
}

private extension Toml.TypedValue {
    /// The toml-test type tag this value would emit (for datetime-kind checks).
    var jsonTag: String? {
        switch self {
        case .offsetDateTime: return "datetime"
        case .localDateTime:  return "datetime-local"
        case .localDate:      return "date-local"
        case .localTime:      return "time-local"
        default:              return nil
        }
    }
}
