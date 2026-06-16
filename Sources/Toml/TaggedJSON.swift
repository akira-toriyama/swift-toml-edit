// Emit a `Toml.TypedValue` as toml-test's tagged-JSON wire format.
//
// The contract (verified against toml-lang/toml-test): every SCALAR becomes a
// two-key JSON object {"type": <tag>, "value": <string>} where the value is
// ALWAYS a JSON string — never a bare JSON number / bool / null. Tables become
// plain JSON objects, arrays become plain JSON arrays, and the eight scalar
// tags are string / integer / float / bool / datetime / datetime-local /
// date-local / time-local. The runner compares SEMANTICALLY (key order and
// whitespace are irrelevant), but we still emit canonical forms (decimal
// integers, round-trippable floats, RFC 3339 datetimes) to be safe.
//
// Hand-rolled (not `JSONEncoder`) so the {type,value} shape and string escaping
// are exact and identical on macOS and Linux.

import Foundation

public extension Toml.TypedValue {
    /// This value as toml-test tagged JSON.
    func taggedJSON() -> String {
        var s = ""
        write(into: &s)
        return s
    }

    private func write(into s: inout String) {
        switch self {
        case .string(let v):         scalar("string", v, &s)
        case .integer(let v):        scalar("integer", String(v), &s)
        case .float(let v):          scalar("float", Toml.canonicalFloat(v), &s)
        case .boolean(let v):        scalar("bool", v ? "true" : "false", &s)
        case .offsetDateTime(let d): scalar("datetime", Toml.render(d), &s)
        case .localDateTime(let d):  scalar("datetime-local", Toml.render(d), &s)
        case .localDate(let d):      scalar("date-local", Toml.render(d), &s)
        case .localTime(let t):      scalar("time-local", Toml.render(t), &s)
        case .array(let xs):
            s += "["
            for (k, x) in xs.enumerated() {
                if k > 0 { s += "," }
                x.write(into: &s)
            }
            s += "]"
        case .table(let kvs):
            s += "{"
            for (k, kv) in kvs.enumerated() {
                if k > 0 { s += "," }
                Toml.jsonString(kv.key, &s)
                s += ":"
                kv.value.write(into: &s)
            }
            s += "}"
        }
    }

    private func scalar(_ tag: String, _ value: String, _ s: inout String) {
        s += "{\"type\":\""
        s += tag
        s += "\",\"value\":"
        Toml.jsonString(value, &s)
        s += "}"
    }
}

extension Toml {
    /// Append a JSON string literal (quotes + minimal escaping) for `v`.
    static func jsonString(_ v: String, _ s: inout String) {
        s += "\""
        for u in v.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\u{08}": s += "\\b"
            case "\u{09}": s += "\\t"
            case "\u{0A}": s += "\\n"
            case "\u{0C}": s += "\\f"
            case "\u{0D}": s += "\\r"
            default:
                if u.value < 0x20 {
                    s += String(format: "\\u%04x", u.value)
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }

    /// A round-trippable canonical float spelling: TOML/JSON `inf`/`-inf`/`nan`
    /// for specials, otherwise Swift's shortest round-trip `Double` description
    /// (which always carries a `.` or `e`, so it is never integer-shaped).
    static func canonicalFloat(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        return String(d)
    }

    static func render(_ d: Toml.LocalDate) -> String {
        String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
    }
    static func render(_ t: Toml.LocalTime) -> String {
        let base = String(format: "%02d:%02d:%02d", t.hour, t.minute, t.second)
        return t.fraction.isEmpty ? base : base + "." + t.fraction
    }
    static func render(_ dt: Toml.DateTime) -> String {
        var out = render(dt.date) + "T" + render(dt.time)
        switch dt.offset {
        case .none:           break
        case .utc:            out += "Z"
        case .hours(let sign, let h, let m):
            out += String(format: "%@%02d:%02d", sign < 0 ? "-" : "+", h, m)
        }
        return out
    }
}
