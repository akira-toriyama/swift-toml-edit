// Toml — the family's shared hand-rolled TOML *subset* parser.
//
// Phase 1.6 of the atelier refactor folds four near-identical in-tree
// parsers (chord 434L / facet 251L / perch 180L / wand 136L) into this
// one pure module. It keeps the family zero-dep (Apple frameworks only,
// no SwiftPM TOML library) while removing the drift between four copies.
//
// chord's 434-line parser is the feature SUPERSET reference, but the
// four diverged on SHAPE and SEMANTICS, not just features:
//   • chord wants a NESTED tree + STRICT throwing parse (dotted keys
//     collapse, nested `[[a.b]]` arrays-of-tables, a synthetic
//     `__line__` per AoT row for warning attribution).
//   • facet / perch / wand want a FLAT model keyed by the *literal*
//     header text (`tables["cast.overlay.trail"]`, `arrays["rules"]`)
//     + LENIENT parsing (a typo loses one line, the daemon survives).
//
// Rather than force one shape and lossily re-project, this module ships
// BOTH skins over one shared scalar/line core:
//
//   • `parse(_:)  throws -> [String: Value]`   — NESTED, STRICT (chord)
//   • `parseFlat(_:) -> Document`              — FLAT, LENIENT (the 3)
//
// Both share the same `Value` model, scalar grammar, comment stripping,
// quote handling, and multi-line-array accumulation. They differ only
// in WHERE a parsed value lands (a nested tree vs. flat literal-keyed
// maps) and in error policy (throw vs. skip-the-line).
//
// Supported (the union of all four, plus the superset deltas):
//   • `key = value` at table/section scope
//   • dotted keys `a.b.c = …` collapse to nested tables (`parse` only)
//   • `[table]` / `[sub.section]` headers; nested for `parse`, literal
//     for `parseFlat`. Quoted segments (`[a."b.c"]`) keep interior dots
//     and are unquoted (`parse`); `parseFlat` keeps the header verbatim.
//   • `[[array-of-tables]]` headers, including nested `[[a.b]]`
//     (`a[last].b` per spec) for `parse`; single-level literal-keyed for
//     `parseFlat`.
//   • inline tables `{ a = 1, "q.k" = 2 }` (single-line)
//   • arrays `[ a, b, c ]`, quote+depth-aware comma split, trailing
//     comma + empty `[]` tolerated — AND multi-line arrays (elements
//     spanning physical lines, inline `#` comments inside tolerated)
//   • scalars: `"…"` (escapes `\" \\ \n \t`, unknown `\x` → `x`),
//     `'…'` literal (verbatim, no escapes), int (Int64), hex int
//     `0x…`, float (Double), bool. Int is tried before float so a bare
//     `2` stays `.int`.
//   • `#` comments to end of line, quote- AND escape-aware (an
//     escaped `\"` inside a basic string doesn't end it). CRLF tolerated.
//
// NOT supported (by design — none of the four configs need them):
//   • multi-line strings (`"""…"""`), multi-line *inline tables*
//     (TOML 1.0 forbids those anyway), date/time literals, nested
//     arrays-of-arrays, integer underscores/octal/binary, inf/nan.
//   • serialization / emit — verified none of the four writes TOML.
//
// Out-of-range / typed clamping is NOT done here — that policy lives in
// each app's Config layer, so a typo's blast radius stays one binding.

import Foundation

public enum Toml {

    /// A parsed TOML value. The case set is chord's superset; the three
    /// flat consumers never construct `.arrayOfTables` and read string
    /// arrays via `asStringArray` rather than a dedicated case.
    public enum Value: Sendable, Equatable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case array([Value])
        case table([String: Value])
        indirect case arrayOfTables([[String: Value]])
    }

    /// Thrown by `parse(_:)` (strict). `parseFlat(_:)` swallows it and
    /// drops the offending line. Lines are 1-based.
    public struct ParseError: Error, CustomStringConvertible, Equatable, Sendable {
        public let line: Int
        public let message: String
        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }
        public var description: String { "line \(line): \(message)" }
    }

    /// The FLAT document `parseFlat(_:)` returns. `tables[""]` is the
    /// top-level scope; every other key is the *literal* header text
    /// (`"cast.overlay.trail"`, `"behavior.\"com.apple.Safari\""`).
    /// `arrays[name]` holds the per-`[[name]]` row list in source order.
    public struct Document: Sendable, Equatable {
        public var tables: [String: [String: Value]]
        public var arrays: [String: [[String: Value]]]
        public init(tables: [String: [String: Value]] = [:],
                    arrays: [String: [[String: Value]]] = [:]) {
            self.tables = tables
            self.arrays = arrays
        }
    }

    /// Synthetic key seeded into every `[[X]]` row (nested `parse` only)
    /// so a consumer can attribute warnings to a real line number. A
    /// user key literally named `__line__` would shadow it — an accepted
    /// trade-off. `parseFlat` does NOT inject it (the flat consumers
    /// don't read it and would otherwise see a spurious row key).
    public static let lineKey = "__line__"

    // MARK: - Nested, strict (chord)

    /// Parse into a NESTED root dictionary, throwing `ParseError` on the
    /// first malformed header / missing `=` / unrecognised scalar.
    /// Dotted keys + headers fold to nested `.table`; `[[a.b]]` appends
    /// to `a[last].b`; every AoT row is seeded with `lineKey`.
    public static func parse(_ source: String) throws -> [String: Value] {
        let lines = source.split(separator: "\n",
                                 omittingEmptySubsequences: false).map(String.init)
        var root: [String: Value] = [:]
        var currentPath: [String] = []
        var inArrayOfTables = false
        var i = 0

        while i < lines.count {
            let lineNo = i + 1
            let line = stripComment(lines[i])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            if line.isEmpty { continue }

            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else {
                    throw ParseError(line: lineNo, message: "unterminated [[...]] header")
                }
                let path = line.dropFirst(2).dropLast(2)
                    .trimmingCharacters(in: .whitespaces)
                currentPath = splitDottedPath(path)
                appendArrayOfTablesRow(&root, path: currentPath, lineNo: lineNo)
                inArrayOfTables = true
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw ParseError(line: lineNo, message: "unterminated [...] header")
                }
                let path = line.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespaces)
                currentPath = splitDottedPath(path)
                inArrayOfTables = false
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                throw ParseError(line: lineNo, message: "expected '=' in '\(line)'")
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var rhs = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rhs = completeMultilineArray(rhs, lines, &i)
            let value = try parseValue(rhs, lineNo: lineNo)
            let dotted = splitDottedPath(key)
            if inArrayOfTables {
                writeIntoArrayOfTablesRow(&root, path: currentPath,
                                          key: dotted, value: value)
            } else {
                write(&root, path: currentPath + dotted, value: value)
            }
        }
        return root
    }

    // MARK: - Flat, lenient (facet / perch / wand)

    /// Parse into the FLAT `Document` keyed by literal header text, never
    /// throwing: a malformed header / missing `=` / unrecognised scalar
    /// drops just that line, the rest still loads. No `lineKey` injection.
    public static func parseFlat(_ source: String) -> Document {
        let lines = source.split(separator: "\n",
                                 omittingEmptySubsequences: false).map(String.init)
        var doc = Document()
        doc.tables[""] = [:]          // top-level scope always present
        var section = ""              // literal header text; "" = top-level
        var arrayKey: String? = nil   // non-nil → inside [[arrayKey]]
        var i = 0

        while i < lines.count {
            let line = stripComment(lines[i])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            if line.isEmpty { continue }

            // [[array-of-tables]] — test the double bracket BEFORE the
            // single, since `[[x]]` also satisfies the single-bracket test.
            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let name = String(line.dropFirst(2).dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
                arrayKey = name
                doc.arrays[name, default: []].append([:])
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                if doc.tables[section] == nil { doc.tables[section] = [:] }
                arrayKey = nil
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var rhs = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rhs = completeMultilineArray(rhs, lines, &i)
            guard !key.isEmpty, !rhs.isEmpty,
                  let value = try? parseValue(rhs, lineNo: 0) else { continue }

            if let k = arrayKey {
                var rows = doc.arrays[k] ?? []
                if rows.isEmpty { rows.append([:]) }
                rows[rows.count - 1][key] = value
                doc.arrays[k] = rows
            } else {
                doc.tables[section, default: [:]][key] = value
            }
        }
        return doc
    }

    // MARK: - Shared scalar / line helpers

    /// Strip an unquoted `#` comment to end of line. A `#` inside a
    /// `"…"` or `'…'` body is preserved (quote-aware), and an escaped
    /// quote `\"` inside a BASIC string does not close it — so a `#`
    /// after a string like `"a \" b"` is still the real comment, not
    /// swallowed as string interior. Literal `'…'` strings process no
    /// escapes (a `\` is verbatim), so escape tracking is gated on the
    /// active quote being `"`.
    private static func stripComment(_ s: String) -> String {
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        var out = ""
        for c in s {
            if inStr {
                if escaped {
                    escaped = false                  // this char is literal
                } else if c == "\\" && quote == "\"" {
                    escaped = true                   // only basic strings escape
                } else if c == quote {
                    inStr = false
                }
                out.append(c)
            } else if c == "\"" || c == "'" {
                inStr = true; quote = c; out.append(c)
            } else if c == "#" {
                break
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// If `rhs` opens a multi-line array (`[` with brackets still open),
    /// pull & comment-strip following physical lines, appending until the
    /// brackets balance (or EOF). Inline tables stay single-line (a `{`
    /// that doesn't close is left malformed for `parseValue` to reject).
    /// An unterminated array runs to EOF — genuinely malformed input.
    private static func completeMultilineArray(_ rhs: String,
                                               _ lines: [String],
                                               _ i: inout Int) -> String {
        guard rhs.hasPrefix("[") else { return rhs }
        var acc = rhs
        while bracketDepth(acc) > 0 && i < lines.count {
            let cont = stripComment(lines[i])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            if cont.isEmpty { continue }
            acc += " " + cont
        }
        return acc
    }

    /// Net bracket/brace depth, quote-aware (brackets inside `"…"`/`'…'`
    /// don't count, and an escaped `\"` doesn't close a basic string).
    /// > 0 means an array/table is still open.
    private static func bracketDepth(_ s: String) -> Int {
        var depth = 0
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        for c in s {
            if inStr {
                if escaped { escaped = false }
                else if c == "\\" && quote == "\"" { escaped = true }
                else if c == quote { inStr = false }
            } else if c == "\"" || c == "'" {
                inStr = true; quote = c
            } else if c == "[" || c == "{" {
                depth += 1
            } else if c == "]" || c == "}" {
                depth -= 1
            }
        }
        return depth
    }

    private static func parseValue(_ raw: String, lineNo: Int) throws -> Value {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return .string(unescape(String(raw.dropFirst().dropLast())))
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
            // Literal string — body verbatim, no escape processing.
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else {
                throw ParseError(line: lineNo, message: "unterminated array")
            }
            let inner = String(raw.dropFirst().dropLast())
            let items = splitCommaSeparated(inner)
            return .array(try items.map { try parseValue($0, lineNo: lineNo) })
        }
        if raw.hasPrefix("{") {
            // Single-line inline table: `{ key = value, "quoted key" = v }`.
            guard raw.hasSuffix("}") else {
                throw ParseError(line: lineNo, message: "unterminated inline table")
            }
            let inner = String(raw.dropFirst().dropLast())
            var t: [String: Value] = [:]
            for entry in splitCommaSeparated(inner) {
                guard let eq = entry.firstIndex(of: "=") else {
                    throw ParseError(line: lineNo,
                                     message: "inline table entry '\(entry)' missing '='")
                }
                let key = unquoteKey(String(entry[..<eq])
                    .trimmingCharacters(in: .whitespaces))
                let rhs = String(entry[entry.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                t[key] = try parseValue(rhs, lineNo: lineNo)
            }
            return .table(t)
        }
        if raw.hasPrefix("0x"), let i = Int64(raw.dropFirst(2), radix: 16) {
            return .int(i)                          // hex int (e.g. colors)
        }
        if let i = Int64(raw) { return .int(i) }    // int before double
        if let d = Double(raw) { return .double(d) }
        throw ParseError(line: lineNo, message: "unrecognised value '\(raw)'")
    }

    /// Comma-split an array / inline-table body, ignoring commas inside
    /// `"…"`/`'…'` and inside nested `[…]`/`{…}`. Trailing/empty pieces
    /// are dropped (so a trailing comma and empty `[]` both work).
    private static func splitCommaSeparated(_ raw: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        var cur = ""
        for c in raw {
            if inStr {
                cur.append(c)
                if escaped { escaped = false }
                else if c == "\\" && quote == "\"" { escaped = true }
                else if c == quote { inStr = false }
            } else if c == "\"" || c == "'" {
                inStr = true; quote = c; cur.append(c)
            } else if c == "[" || c == "{" {
                depth += 1; cur.append(c)
            } else if c == "]" || c == "}" {
                depth -= 1; cur.append(c)
            } else if c == "," && depth == 0 {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            } else {
                cur.append(c)
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// Split a dotted key/header on top-level dots, keeping quoted
    /// segments intact (`a."b.c"` → `[a, "b.c" unquoted]`) and unquoting
    /// each segment. Plain `a.b.c` → `[a, b, c]` (identical to a naive
    /// split, so chord's quote-free paths are unchanged).
    private static func splitDottedPath(_ s: String) -> [String] {
        var segs: [String] = []
        var cur = ""
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        for c in s {
            if inStr {
                cur.append(c)
                if escaped { escaped = false }
                else if c == "\\" && quote == "\"" { escaped = true }
                else if c == quote { inStr = false }
            } else if c == "\"" || c == "'" {
                inStr = true; quote = c; cur.append(c)
            } else if c == "." {
                segs.append(cur); cur = ""
            } else {
                cur.append(c)
            }
        }
        segs.append(cur)
        return segs.map { unquoteKey($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Strip a matching surrounding quote pair (`"…"` or `'…'`) from a
    /// key. Leaves an unquoted key untouched.
    private static func unquoteKey(_ raw: String) -> String {
        if raw.count >= 2 {
            let f = raw.first!, l = raw.last!
            if (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                return String(raw.dropFirst().dropLast())
            }
        }
        return raw
    }

    /// Decode the four minimal escapes in a double-quoted body; an
    /// unknown escape `\x` emits `x` (drops the backslash) — the superset
    /// of chord's fixed-set and perch's char-walker behaviours.
    private static func unescape(_ body: String) -> String {
        var out = ""
        var it = body.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:   out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: - Nested write / array-of-tables drill (chord)

    private static func write(_ root: inout [String: Value],
                              path: [String], value: Value) {
        guard !path.isEmpty else { return }
        if path.count == 1 { root[path[0]] = value; return }
        var inner: [String: Value]
        if case .table(let t) = root[path[0]] { inner = t } else { inner = [:] }
        writeInner(&inner, path: Array(path.dropFirst()), value: value)
        root[path[0]] = .table(inner)
    }

    private static func writeInner(_ table: inout [String: Value],
                                   path: [String], value: Value) {
        if path.count == 1 { table[path[0]] = value; return }
        var inner: [String: Value]
        if case .table(let t) = table[path[0]] { inner = t } else { inner = [:] }
        writeInner(&inner, path: Array(path.dropFirst()), value: value)
        table[path[0]] = .table(inner)
    }

    private static func appendArrayOfTablesRow(_ root: inout [String: Value],
                                               path: [String], lineNo: Int) {
        guard !path.isEmpty else { return }
        let seed: [String: Value] = [lineKey: .int(Int64(lineNo))]
        if path.count == 1 {
            var rows: [[String: Value]]
            if case .arrayOfTables(let e) = root[path[0]] { rows = e } else { rows = [] }
            rows.append(seed)
            root[path[0]] = .arrayOfTables(rows)
            return
        }
        // `[[a.b]]` appends to `a[last].b`: when `a` is already an AoT,
        // drill into its last row rather than shadowing it.
        if case .arrayOfTables(var rows) = root[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            appendArrayOfTablesRowInner(&last, path: Array(path.dropFirst()), lineNo: lineNo)
            rows[rows.count - 1] = last
            root[path[0]] = .arrayOfTables(rows)
            return
        }
        var inner: [String: Value]
        if case .table(let t) = root[path[0]] { inner = t } else { inner = [:] }
        appendArrayOfTablesRowInner(&inner, path: Array(path.dropFirst()), lineNo: lineNo)
        root[path[0]] = .table(inner)
    }

    private static func appendArrayOfTablesRowInner(
        _ table: inout [String: Value], path: [String], lineNo: Int
    ) {
        let seed: [String: Value] = [lineKey: .int(Int64(lineNo))]
        if path.count == 1 {
            var rows: [[String: Value]]
            if case .arrayOfTables(let e) = table[path[0]] { rows = e } else { rows = [] }
            rows.append(seed)
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        if case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            appendArrayOfTablesRowInner(&last, path: Array(path.dropFirst()), lineNo: lineNo)
            rows[rows.count - 1] = last
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        var inner: [String: Value]
        if case .table(let t) = table[path[0]] { inner = t } else { inner = [:] }
        appendArrayOfTablesRowInner(&inner, path: Array(path.dropFirst()), lineNo: lineNo)
        table[path[0]] = .table(inner)
    }

    private static func writeIntoArrayOfTablesRow(
        _ root: inout [String: Value], path: [String],
        key: [String], value: Value
    ) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            guard case .arrayOfTables(var rows) = root[path[0]], !rows.isEmpty else { return }
            var row = rows[rows.count - 1]
            writeInner(&row, path: key, value: value)
            rows[rows.count - 1] = row
            root[path[0]] = .arrayOfTables(rows)
            return
        }
        if case .arrayOfTables(var rows) = root[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            writeIntoArrayOfTablesRowInner(&last, path: Array(path.dropFirst()),
                                           key: key, value: value)
            rows[rows.count - 1] = last
            root[path[0]] = .arrayOfTables(rows)
            return
        }
        guard case .table(var inner) = root[path[0]] else { return }
        writeIntoArrayOfTablesRowInner(&inner, path: Array(path.dropFirst()),
                                       key: key, value: value)
        root[path[0]] = .table(inner)
    }

    private static func writeIntoArrayOfTablesRowInner(
        _ table: inout [String: Value], path: [String],
        key: [String], value: Value
    ) {
        if path.count == 1 {
            guard case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty else { return }
            var row = rows[rows.count - 1]
            writeInner(&row, path: key, value: value)
            rows[rows.count - 1] = row
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        if case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            writeIntoArrayOfTablesRowInner(&last, path: Array(path.dropFirst()),
                                           key: key, value: value)
            rows[rows.count - 1] = last
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        guard case .table(var inner) = table[path[0]] else { return }
        writeIntoArrayOfTablesRowInner(&inner, path: Array(path.dropFirst()),
                                       key: key, value: value)
        table[path[0]] = .table(inner)
    }
}

// MARK: - Convenience accessors

public extension Toml.Value {
    /// Only `.string`.
    var asString: String? { if case .string(let s) = self { return s }; return nil }
    /// Only `.int`, returned as a native `Int` (the family field width).
    /// Does NOT coerce `.double`/`.bool` — int-vs-double discrimination
    /// is load-bearing for well-formed-ms vs fractional-knob reads.
    var asInt: Int? { if case .int(let i) = self { return Int(truncatingIfNeeded: i) }; return nil }
    /// Only `.int`, as the stored `Int64` (chord's raw-width escape hatch).
    var asInt64: Int64? { if case .int(let i) = self { return i }; return nil }
    /// `.double` passthrough; `.int` widened to `Double`.
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        default:             return nil
        }
    }
    /// Only `.bool`.
    var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
    /// The generic array.
    var asArray: [Toml.Value]? { if case .array(let a) = self { return a }; return nil }
    /// `.array` projected to its string elements (non-strings dropped) —
    /// the replacement for the old per-app `.stringArray` case.
    var asStringArray: [String]? {
        if case .array(let a) = self { return a.compactMap(\.asString) }
        return nil
    }
    /// Inline / nested table.
    var asTable: [String: Toml.Value]? { if case .table(let t) = self { return t }; return nil }
    /// Array of tables (chord + wand).
    var asArrayOfTables: [[String: Toml.Value]]? {
        if case .arrayOfTables(let r) = self { return r }; return nil
    }
}
