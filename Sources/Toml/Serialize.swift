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
    /// Serialize a document (this must be a `.table`) to TOML.
    func serializeDocument() -> String {
        guard case .table(let kvs) = self else {
            // A non-table top level isn't a valid TOML document; emit nothing.
            return ""
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
