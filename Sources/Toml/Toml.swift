// The config-oriented, LOSSY READ projection: the value-only read path the
// atelier apps use for config, where a plain dict/tree of values is wanted,
// not a format-preserving document. Full TOML 1.0 (both directions) lives in
// the sibling files listed at the bottom.
//
// Two skins over one shared scalar core, because the consumers diverged on
// SHAPE and on ERROR POLICY:
//   • `parse(_:)  throws -> [String: Value]`     — NESTED, STRICT (chord):
//     dotted keys collapse, `[[a.b]]` nests, every AoT row is a `Row`
//     carrying the `SourceSpan` of its header for warning attribution
//     (Span.swift).
//   • `parseFlat(_:) -> Document`                — FLAT, LENIENT (facet /
//     perch / wand): tables keyed by the LITERAL header text
//     (`tables["cast.overlay.trail"]`), and a malformed line is dropped
//     rather than thrown so a typo costs one binding, not the daemon.
//   • `parseWithSpans(_:) throws -> SpannedTree` — `parse`'s tree plus
//     per-entry / per-header line+column spans (ParseWithSpans.swift). It is
//     the ONE strict engine: `parse` returns its `.tree`.
//
// The skins share `Value` and the scalar grammar: the strict fold replays
// every value through `parseFlat`'s decoder (`decodeWholeScalar`), so the two
// can never disagree about what a scalar means. Both split physical lines
// with the tiler's scalar-based `lexLines`, so CRLF reads like LF on either.
// `parse` rides the lossless tiler (conformance-grade headers / keys);
// `parseFlat` stays a line scanner BY DESIGN — skip-the-bad-line leniency
// cannot ride a strict tiler without an error-recovery story nobody needs.
//
// Grammar boundary of this projection: single-line inline tables; single-
// AND multi-line arrays (inline `#` comments inside tolerated, trailing
// comma and empty `[]` accepted); basic strings with exactly the escapes
// `\" \\ \n \t` (an unknown `\x` yields `x`); literal strings verbatim;
// Int64 decimal and `0x` hex; Double; bool. Int is tried before float so a
// bare `2` stays `.int` — the int-vs-double distinction is load-bearing for
// the consumers' whole-ms vs fractional-knob reads.
//
// Deliberately NOT surfaced: multi-line strings, date/time literals, integer
// underscores / octal / binary, inf/nan, arrays-of-arrays, emit. The family's
// configs don't need them on this path; do not widen the grammar here — the
// full spec is already available in the sibling files:
//   • lossless DOM: Annotated.swift / AnnotatedParse.swift
//   • strict typed decode: DecodeStrict.swift / TypedValue.swift / TypedTree.swift
//   • encode / emit: Serialize.swift / TaggedJSON.swift
//
// Out-of-range / typed clamping is NOT done here — that policy lives in each
// app's Config layer, so a typo's blast radius stays one binding.

import Foundation

public enum Toml {

    /// A parsed TOML value. `.arrayOfTables` holds `[Row]` (fields + the
    /// `[[header]]` `SourceSpan`) rather than a bare `[[String: Value]]`, so
    /// the nested strict `parse` can attribute warnings to a source line
    /// without a synthetic dict key. Only `parse` constructs it; `parseFlat`
    /// keeps its rows as plain `[[String: Value]]` in `Document.arrays`.
    public enum Value: Sendable, Equatable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case array([Value])
        case table([String: Value])
        indirect case arrayOfTables([Row])
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

    // MARK: - Nested, strict (chord)

    /// Parse into a NESTED root dictionary, throwing `ParseError` on the
    /// first malformed header / missing `=` / unrecognised scalar.
    /// Dotted keys + headers fold to nested `.table`; `[[a.b]]` appends
    /// to `a[last].b`; every AoT row is a `Row` carrying the `SourceSpan`
    /// of its `[[header]]` (see Span.swift).
    ///
    /// Delegates to `parseWithSpans` — ONE strict engine, so the tree and
    /// the spans can never disagree. The strictness is the tiler's: a
    /// control char in a comment, a `[]` header, an invalid bare key and any
    /// triple-quoted spelling throw (pinned in ParseWithSpansTests). Callers
    /// that also want source locations call `parseWithSpans` directly.
    public static func parse(_ source: String) throws -> [String: Value] {
        try parseWithSpans(source).tree
    }

    // MARK: - Flat, lenient (facet / perch / wand)

    /// Parse into the FLAT `Document` keyed by literal header text, never
    /// throwing: a malformed header / missing `=` / unrecognised scalar
    /// drops just that line, the rest still loads. Flat rows are plain
    /// `[[String: Value]]` (no `Row`/span — the flat consumers don't
    /// attribute warnings to source lines).
    public static func parseFlat(_ source: String) -> Document {
        // Physical lines via the scalar-based `lexLines`, NOT
        // `split(separator: "\n")`: a Swift `Character` folds "\r\n" into one
        // grapheme, so a Character-based split sees a CRLF document as ONE
        // line and leniently drops nearly all of it.
        let lines = lexLines(stripBOM(source)).map(\.text)
        var doc = Document()
        doc.tables[""] = [:]
        var section = ""
        var arrayKey: String? = nil
        var i = 0

        while i < lines.count {
            let line = stripComment(lines[i])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            i += 1
            if line.isEmpty { continue }

            // `[[x]]` also satisfies the single-bracket test — order matters.
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

            guard let eq = firstTopLevelEquals(line) else { continue }
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

    /// Drop a single optional leading UTF-8 BOM (U+FEFF) at offset 0 so the
    /// first key is not corrupted into `"\u{FEFF}key"`. Only at the very start.
    private static func stripBOM(_ s: String) -> String {
        s.unicodeScalars.first == "\u{FEFF}" ? String(s.unicodeScalars.dropFirst()) : s
    }

    /// 1-based column of the first non-`space`/`tab` character on `line`
    /// (just past the leading indentation) — the `SourceSpan.column` of a
    /// header. A blank line yields the column past its end; headers are
    /// never blank, so that case doesn't arise.
    static func leadingColumn(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count + 1
    }

    // MARK: - Shared scalar / line helpers

    /// Strip an unquoted `#` comment to end of line. Quote-aware, and an
    /// escaped `\"` inside a BASIC string does not close it — otherwise the
    /// `#` after `"a \" b"` would be swallowed as string interior and the
    /// whole binding lost. Escape tracking is gated on the active quote being
    /// `"` because a literal `'…'` string processes no escapes.
    private static func stripComment(_ s: String) -> String {
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        var out = ""
        for c in s {
            if inStr {
                if escaped {
                    escaped = false
                } else if c == "\\" && quote == "\"" {
                    escaped = true
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

    /// Pull following physical lines into an array value until its brackets
    /// balance (or EOF — an unterminated array is genuinely malformed).
    /// Inline tables stay single-line on purpose: a `{` that doesn't close is
    /// left for `parseValue` to reject.
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

    /// The key/value separator: the first `=` OUTSIDE a `"…"`/`'…'` string,
    /// so an `=` inside a quoted key (`"a=b" = 1`) is not mistaken for it.
    private static func firstTopLevelEquals(_ s: String) -> String.Index? {
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        for idx in s.indices {
            let c = s[idx]
            if inStr {
                if escaped { escaped = false }
                else if c == "\\" && quote == "\"" { escaped = true }
                else if c == quote { inStr = false }
            } else if c == "\"" || c == "'" {
                inStr = true; quote = c
            } else if c == "=" {
                return idx
            }
        }
        return nil
    }

    private static func parseValue(_ raw: String, lineNo: Int) throws -> Value {
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return .string(unescape(String(raw.dropFirst().dropLast())))
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
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
            guard raw.hasSuffix("}") else {
                throw ParseError(line: lineNo, message: "unterminated inline table")
            }
            let inner = String(raw.dropFirst().dropLast())
            var t: [String: Value] = [:]
            for entry in splitCommaSeparated(inner) {
                guard let eq = firstTopLevelEquals(entry) else {
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
            return .int(i)
        }
        if let i = Int64(raw) { return .int(i) }
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

    /// The LOSSY dotted-path finisher: split on top-level dots, keeping quoted
    /// segments intact (`a."b.c"` → `["a", "b.c"]`), and strip each segment's
    /// quote pair WITHOUT decoding escapes. `parseWithSpans` re-lexes keys
    /// through this same finisher so the derived tree keeps the projection's
    /// literal-escape key identity (see `scanDottedSegments`).
    static func splitDottedPath(_ s: String) -> [String] {
        scanDottedSegments(s).map { unquoteKey($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Split a dotted key / header on top-level dots into the RAW,
    /// still-quoted, whitespace-included segments. One scanner, TWO
    /// finishers: the lossy projection keeps escapes literal (`unquoteKey`),
    /// the lossless DOM lookup decodes them (`lexUnquoteKey`). Do NOT collapse
    /// the finishers into one — the divergence is a pinned consumer contract
    /// (LossyProjectionTests.lossyKeyEscapesStayLiteral /
    /// ReviewFixesTests.dottedPathLookupDecodesKeyEscapes).
    static func scanDottedSegments(_ s: String) -> [String] {
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
        return segs
    }

    /// Strip a matching surrounding quote pair from a key; escapes inside
    /// stay literal (the lossy finisher — see `scanDottedSegments`).
    private static func unquoteKey(_ raw: String) -> String {
        if raw.count >= 2 {
            let f = raw.first!, l = raw.last!
            if (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                return String(raw.dropFirst().dropLast())
            }
        }
        return raw
    }

    /// Decode the four escapes in a double-quoted body; an unknown escape
    /// `\x` emits `x`. This is the union of what the consumers' former
    /// per-app parsers accepted, so no existing config changes meaning.
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

    // Internal (not private): the WRITERS of the strict nested tree —
    // `parseWithSpans`'s DOM fold (and therefore `parse`) builds through
    // them. Do not fork them: the tree semantics `parse` promises live here.
    // All three drill into an array-of-tables' LAST element on the way
    // (TOML 1.0: `[aot.sub]` and `[[aot.sub]]` bind to the most recent
    // element); overwriting the AoT node with a fresh table would drop the
    // array and every field already written to that element.

    static func write(_ table: inout [String: Value],
                      path: [String], value: Value) {
        guard !path.isEmpty else { return }
        if path.count == 1 { table[path[0]] = value; return }
        if case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            write(&last.fields, path: Array(path.dropFirst()), value: value)
            rows[rows.count - 1] = last
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        var inner: [String: Value]
        if case .table(let t) = table[path[0]] { inner = t } else { inner = [:] }
        write(&inner, path: Array(path.dropFirst()), value: value)
        table[path[0]] = .table(inner)
    }

    static func appendArrayOfTablesRow(_ table: inout [String: Value],
                                       path: [String], span: SourceSpan) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            var rows: [Row]
            if case .arrayOfTables(let e) = table[path[0]] { rows = e } else { rows = [] }
            rows.append(Row(span: span))
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        if case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            appendArrayOfTablesRow(&last.fields, path: Array(path.dropFirst()), span: span)
            rows[rows.count - 1] = last
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        var inner: [String: Value]
        if case .table(let t) = table[path[0]] { inner = t } else { inner = [:] }
        appendArrayOfTablesRow(&inner, path: Array(path.dropFirst()), span: span)
        table[path[0]] = .table(inner)
    }

    static func writeIntoArrayOfTablesRow(
        _ table: inout [String: Value], path: [String],
        key: [String], value: Value
    ) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            guard case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty else { return }
            var row = rows[rows.count - 1]
            write(&row.fields, path: key, value: value)
            rows[rows.count - 1] = row
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        if case .arrayOfTables(var rows) = table[path[0]], !rows.isEmpty {
            var last = rows[rows.count - 1]
            writeIntoArrayOfTablesRow(&last.fields, path: Array(path.dropFirst()),
                                      key: key, value: value)
            rows[rows.count - 1] = last
            table[path[0]] = .arrayOfTables(rows)
            return
        }
        guard case .table(var inner) = table[path[0]] else { return }
        writeIntoArrayOfTablesRow(&inner, path: Array(path.dropFirst()),
                                  key: key, value: value)
        table[path[0]] = .table(inner)
    }
}

// MARK: - Convenience accessors

public extension Toml.Value {
    var asString: String? { if case .string(let s) = self { return s }; return nil }
    /// Does NOT coerce `.double`/`.bool`: int-vs-double discrimination is
    /// load-bearing for the consumers' whole-ms vs fractional-knob reads.
    var asInt: Int? { if case .int(let i) = self { return Int(truncatingIfNeeded: i) }; return nil }
    var asInt64: Int64? { if case .int(let i) = self { return i }; return nil }
    /// `.int` is widened to `Double`; the reverse never happens (see `asInt`).
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        default:             return nil
        }
    }
    var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var asArray: [Toml.Value]? { if case .array(let a) = self { return a }; return nil }
    /// Non-string elements are dropped, not an error — the lenient consumers
    /// read string lists this way and must survive a stray element.
    var asStringArray: [String]? {
        if case .array(let a) = self { return a.compactMap(\.asString) }
        return nil
    }
    var asTable: [String: Toml.Value]? { if case .table(let t) = self { return t }; return nil }
    var asArrayOfTables: [Toml.Row]? {
        if case .arrayOfTables(let r) = self { return r }; return nil
    }
}
