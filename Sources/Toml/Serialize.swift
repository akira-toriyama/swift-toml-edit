// Serialize a `Toml.TypedValue` to TOML, for the toml-test ENCODER direction.
//
// The encoder is graded by ROUND-TRIP: the runner re-decodes our output with a
// blessed reference decoder and compares the result semantically to the input.
// So the output need not match any golden text or preserve formatting — it only
// has to be valid TOML that decodes back to the same data. We therefore emit the
// simplest always-correct shape: every root key on its own line, with any
// composite value (table or array) written INLINE (`{…}` / `[…]`). Inline tables
// and arrays nest arbitrarily and can represent any table / array-of-tables /
// scalar structure on a single line, which sidesteps header-ordering concerns
// entirely while remaining spec-valid.

public extension Toml.TypedValue {
    /// Serialize a document (this must be a `.table`) to TOML. Throws if the top
    /// level is not a table (a scalar / array root is not a TOML document — the
    /// encoder must reject it, distinct from a legitimately empty table `{}`,
    /// which serializes to "").
    func serializeDocument() throws -> String {
        guard case .table(let kvs) = self else {
            throw Toml.ParseError(line: 0, message: "top-level value is not a table; cannot encode as a TOML document")
        }
        var out = ""
        for (key, value) in kvs {
            out += Toml.encodeKey(key)
            out += " = "
            value.appendInline(to: &out)
            out += "\n"
        }
        return out
    }

    /// Append this value in inline form (`{…}` for tables, `[…]` for arrays,
    /// a literal for scalars).
    fileprivate func appendInline(to out: inout String) {
        switch self {
        case .string(let s):         out += Toml.encodeBasicString(s)
        case .integer(let v):        out += String(v)
        case .float(let v):          out += Toml.canonicalFloat(v)
        case .boolean(let v):        out += v ? "true" : "false"
        case .offsetDateTime(let d): out += Toml.render(d)
        case .localDateTime(let d):  out += Toml.render(d)
        case .localDate(let d):      out += Toml.render(d)
        case .localTime(let t):      out += Toml.render(t)
        case .array(let xs):
            out += "["
            for (i, x) in xs.enumerated() {
                if i > 0 { out += ", " }
                x.appendInline(to: &out)
            }
            out += "]"
        case .table(let kvs):
            out += "{"
            for (i, kv) in kvs.enumerated() {
                if i > 0 { out += ", " }
                out += Toml.encodeKey(kv.key)
                out += " = "
                kv.value.appendInline(to: &out)
            }
            out += "}"
        }
    }
}

public extension Toml {
    /// Serialize one lossy `Toml.Value` to its TOML value-token spelling —
    /// the public value serializer the per-element edit ops build a new
    /// entry `raw` from (v2.1.0). One wrapper over the internal spellings so
    /// a consumer never re-implements the case switch:
    ///
    ///   `.string` → a basic string (always double-quoted, TOML escapes
    ///               applied — the ONE quoting style emitted)
    ///   `.int` / `.bool` → their literal spellings
    ///   `.double` → `canonicalFloat` (always float-shaped; `inf`/`nan`
    ///               spelled out)
    ///   `.array` → single-line `[a, b]`; `[]` when empty
    ///   `.table` → a single-line inline table with KEYS SORTED (the dict is
    ///              unordered; sorting keeps the output deterministic)
    ///   `.arrayOfTables` → OUT of the v2.1.0 contract (only chord's nested
    ///              `parse` constructs it in value position); encoded
    ///              best-effort as an array of inline tables, which decodes
    ///              back to equivalent data
    static func encode(_ value: Toml.Value) -> String {
        switch value {
        case .string(let s):  return encodeBasicString(s)
        case .int(let i):     return String(i)
        case .double(let d):  return canonicalFloat(d)
        case .bool(let b):    return b ? "true" : "false"
        case .array(let xs):
            return "[" + xs.map(encode).joined(separator: ", ") + "]"
        case .table(let t):
            let body = t.keys.sorted()
                .map { "\(encodeKey($0)) = \(encode(t[$0]!))" }
                .joined(separator: ", ")
            return "{" + body + "}"
        case .arrayOfTables(let rows):
            return "[" + rows.map { encode(.table($0.fields)) }
                .joined(separator: ", ") + "]"
        }
    }
}

extension Toml {
    /// A key as a bare key if it is a non-empty ASCII `[A-Za-z0-9_-]+`, else a
    /// basic-quoted key (empty keys included).
    static func encodeKey(_ k: String) -> String {
        if !k.isEmpty && k.unicodeScalars.allSatisfy({
            ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z")
                || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-"
        }) {
            return k
        }
        return encodeBasicString(k)
    }

    /// A basic string literal: double-quoted, with the TOML escapes applied and
    /// any remaining control character emitted as `\uXXXX`.
    static func encodeBasicString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"":     out += "\\\""
            case "\\":     out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }
}
