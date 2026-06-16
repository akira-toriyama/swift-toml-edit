import Testing
import Foundation
@testable import Toml

// Coverage for the encoder direction (tagged JSON → TOML). The authoritative
// gate is the official toml-test encoder job (205/205); these pin the corners
// the encoder's round-trip correctness depends on — the type TAG is honoured
// (a float spelled like an int stays a float) and every emitted float is
// float-shaped.
@Suite struct SerializeTests {

    /// tagged JSON string → TypedValue → TOML, then re-decode and compare.
    private func roundTrip(_ json: String, _ loc: SourceLocation = #_sourceLocation) throws -> Toml.TypedValue {
        let value = try Toml.decodeTaggedJSON(Data(json.utf8))
        let toml = try value.serializeDocument()
        return try Toml.Annotated(parsing: toml).typedTree()
    }

    @Test func floatTagBeatsIntegerShape() throws {
        // A float value spelled like an integer must round-trip AS a float.
        let t = try roundTrip(#"{"x":{"type":"float","value":"9007199254740991"}}"#)
        guard case .table(let kvs) = t, case .float(let d) = kvs[0].value else {
            Issue.record("expected a float"); return
        }
        #expect(d == 9007199254740991.0)
    }

    @Test func floatAlwaysFloatShaped() {
        #expect(Toml.canonicalFloat(9007199254740991.0).contains("."))   // not "9007199254740991"
        #expect(Toml.canonicalFloat(0.0) == "0.0")
        #expect(Toml.canonicalFloat(-.infinity) == "-inf")
        #expect(Toml.canonicalFloat(.nan) == "nan")
    }

    @Test func keysQuotedWhenNeeded() {
        #expect(Toml.encodeKey("bare-key_1") == "bare-key_1")
        #expect(Toml.encodeKey("has space") == #""has space""#)
        #expect(Toml.encodeKey("") == #""""#)
        #expect(Toml.encodeKey("a.b") == #""a.b""#)
    }

    @Test func nestedTablesAndArraysRoundTrip() throws {
        let json = #"""
        {
          "srv": {
            "ports": [{"type":"integer","value":"80"},{"type":"integer","value":"443"}],
            "meta": {"name": {"type":"string","value":"x"}, "on": {"type":"bool","value":"true"}}
          }
        }
        """#
        let t = try roundTrip(json)
        // Navigate srv.meta.name == "x", srv.ports == [80, 443].
        guard case .table(let root) = t,
              case .table(let srv)? = root.first(where: { $0.key == "srv" })?.value,
              case .array(let ports)? = srv.first(where: { $0.key == "ports" })?.value,
              case .table(let meta)? = srv.first(where: { $0.key == "meta" })?.value else {
            Issue.record("structure"); return
        }
        #expect(ports == [.integer(80), .integer(443)])
        #expect(meta.first(where: { $0.key == "name" })?.value == .string("x"))
    }

    @Test func stringEscapingRoundTrip() throws {
        let t = try roundTrip(#"{"s":{"type":"string","value":"tab\tquote\"newline\nbackslash\\"}}"#)
        guard case .table(let kvs) = t else { Issue.record("table"); return }
        #expect(kvs[0].value == .string("tab\tquote\"newline\nbackslash\\"))
    }
}
