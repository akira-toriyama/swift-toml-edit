// parseWithSpans — the lossy nested strict parse, derived from the lossless
// `Annotated` DOM, with per-entry / per-header source locations (chord#159).
// Since v3 this is the ONE strict engine: `Toml.parse` returns this fold's
// `.tree` (the original line-based scanner is retired).
//
// This is the post-M2 unification the module gated on the lossless parser
// passing full toml-test (it does — CI runs the official suite): tile the
// document with `Annotated(parsing:)` and FOLD the DOM into the nested
// `[String: Value]` tree the strict `parse` always produced, using the SAME
// proven write helpers (`write` / `appendArrayOfTablesRow` /
// `writeIntoArrayOfTablesRow`). Because rendering an unedited DOM is
// byte-identical to the source, each node's line/column is derived exactly by
// accumulating the newlines of the raw spans walked so far — no coordinates
// are stored in the DOM (edits would stale them).
//
// The derivation preserves the LOSSY projection's semantics, not the strict
// decoder's:
//   • keys are re-lexed from the raw spelling with the lossy finisher
//     (`splitDottedPath`), so quoted-key escapes stay LITERAL — the pinned
//     `parse` behavior (see `lossyKeyEscapesStayLiteral`), NOT the DOM's
//     escape-decoded `Entry.key` / `Block.path`;
//   • values go through the same M1 scalar grammar (`decodeScalar`), so a
//     datetime or a real multi-line string still throws `unrecognised value`;
//   • duplicate keys last-write-win; redefinition is NOT policed (that is
//     `typedTree()`'s job, not the lossy projection's).
//
// The fold's strict-parse contract at the points where it deliberately
// diverged from the retired line scanner (each pinned in ParseWithSpansTests;
// all in the correct-TOML direction):
//   • CRLF terminators: documents parse correctly (multi-line arrays
//     included — the retired scanner's Character-based split folded "\r\n"
//     and threw on any multi-entry CRLF document). The reverse arm: a raw
//     CRLF *inside* a single-line string is split by the tiler into an
//     unterminated string and throws;
//   • triple-quoted spellings: any `"""`/`'''` string SPELLING in a value
//     throws `unrecognised value` — the M1 grammar has no multi-line strings
//     (the datetime stance). This is also the stability boundary: past a
//     triple quote naive quote models disagree (quote runs ≥ 4,
//     `#`-after-parity), and a lenient read would make this fold silently
//     drop over-consumed lines — rejecting is the only contract that cannot
//     silently misparse;
//   • strictness inherited from the tiler rejects documents the old scanner
//     silently tolerated: a control char in a comment (lexValidateComment), a
//     degenerate header like `[]`, an invalid bare key (lexDottedPathStrict).
//
// Span conventions (all 1-based, columns in Unicode scalars):
//   • an ENTRY records its key's first character and its value's first
//     character, keyed by the LEAF path the assignment lands on (a dotted key
//     `a.b = 1` records at [key(a), key(b)]; intermediates get nothing);
//   • a HEADER records its `[` position (just past the indentation — the same
//     column `Row.span` carries), keyed by its attributed path: an AoT element
//     includes its index ([key(rule), index(1)]), a std table reopening an
//     AoT's last element drills like the tree does;
//   • inline-table INTERIORS are not indexed — the entry is the unit (YAGNI:
//     chord's warnings point at fields, which are scalars or arrays);
//   • spans mirror the tree's last-write-wins, so the surviving value owns the
//     path; a span under a subtree that a later assignment REPLACED wholesale
//     (e.g. `k.x = 1` then `k = 5`) dangles — resolve spans against the tree
//     you read values from and treat a miss as "no location", same as a nil
//     `Row.span`.

import Foundation

public extension Toml {

    /// One step of a value's address in the nested `parse` tree: a table key,
    /// or an element index inside an array-of-tables.
    enum PathSegment: Sendable, Hashable, CustomStringConvertible {
        case key(String)
        case index(Int)

        public var description: String {
            switch self {
            case .key(let k):   return k
            case .index(let i): return "[\(i)]"
            }
        }
    }

    /// The two locations a `key = value` assignment can be blamed at: the
    /// key's first character (unknown-key warnings) and the value's first
    /// character (malformed-value warnings).
    struct EntrySpans: Sendable, Equatable, Hashable {
        public var key: SourceSpan
        public var value: SourceSpan
        public init(key: SourceSpan, value: SourceSpan) {
            self.key = key
            self.value = value
        }
    }

    /// `parseWithSpans`'s result: the strict nested tree, plus the location
    /// index the tree itself cannot carry (the tree's Equatable identity is
    /// plain `[String: Value]` — span data lives beside it, never inside it).
    struct SpannedTree: Sendable, Equatable {
        /// The nested root — exactly what `Toml.parse(source)` returns
        /// (`parse` delegates here since v3).
        public var tree: [String: Value]
        /// Leaf-path → key/value locations, one per surviving assignment.
        public var entrySpans: [[PathSegment]: EntrySpans]
        /// Attributed-path → `[header]` / `[[header]]` location. AoT elements
        /// are also reachable via `Row.span`; std-table headers only here.
        public var headerSpans: [[PathSegment]: SourceSpan]

        public init(tree: [String: Value] = [:],
                    entrySpans: [[PathSegment]: EntrySpans] = [:],
                    headerSpans: [[PathSegment]: SourceSpan] = [:]) {
            self.tree = tree
            self.entrySpans = entrySpans
            self.headerSpans = headerSpans
        }

        /// Variadic sugar: `r.entrySpan(.key("bindings"), .index(0), .key("input"))`.
        public func entrySpan(_ path: PathSegment...) -> EntrySpans? { entrySpans[path] }
        /// Variadic sugar: `r.headerSpan(.key("bindings"), .index(0))`.
        public func headerSpan(_ path: PathSegment...) -> SourceSpan? { headerSpans[path] }
    }

    /// Parse into the SAME nested strict tree as `parse(_:)`, deriving it from
    /// the lossless `Annotated` DOM, and additionally report where every
    /// surviving assignment and header lives (line + column) — the input for
    /// column-precise `(config.toml:N:C)` diagnostics.
    static func parseWithSpans(_ source: String) throws -> SpannedTree {
        let dom = try Annotated(parsing: source)

        var tree: [String: Value] = [:]
        var entrySpans: [[PathSegment]: EntrySpans] = [:]
        var headerSpans: [[PathSegment]: SourceSpan] = [:]

        // Line derivation: render() of an unedited DOM is byte-identical to
        // `source`, so walking the raw spans in document order and counting
        // newlines yields each construct's exact 1-based physical line. ("\n"
        // is counted on Unicode scalars — a CRLF terminator contains one.)
        var newlinesConsumed = 0
        func advance(_ s: String) {
            for u in s.unicodeScalars where u == "\n" { newlinesConsumed += 1 }
        }
        func currentLine() -> Int { newlinesConsumed + 1 }

        // The tree path an assignment/header LANDED on, indices included:
        // replays the write helpers' drill choice read-only, against the
        // just-written tree — an array-of-tables node on the way resolves to
        // its LAST element, exactly like `write` / `appendArrayOfTablesRow`.
        func attributedPath(_ segments: [String]) -> [PathSegment] {
            var out: [PathSegment] = []
            out.reserveCapacity(segments.count + 2)
            var cur: [String: Value]? = tree
            for seg in segments {
                out.append(.key(seg))
                guard let table = cur else { continue }
                switch table[seg] {
                case .arrayOfTables(let rows) where !rows.isEmpty:
                    out.append(.index(rows.count - 1))
                    cur = rows[rows.count - 1].fields
                case .table(let sub):
                    cur = sub
                default:
                    cur = nil
                }
            }
            return out
        }

        func foldEntry(_ e: Annotated.Entry, blockPath: [String], inAoT: Bool) throws {
            advance(e.leading)
            let line = currentLine()
            let scalars = Array(e.raw.unicodeScalars)

            // Key + value columns on the entry's first physical line (a value
            // never STARTS on a continuation line: the tiler only continues a
            // value that already opened a bracket or multi-line string).
            var k = 0
            while k < scalars.count, scalars[k] == " " || scalars[k] == "\t" { k += 1 }
            let keyColumn = k + 1
            guard let eq = lexFindEq(scalars) else {
                throw ParseError(line: line, message: "expected '=' in '\(e.raw)'")
            }
            var v = eq + 1
            while v < scalars.count, scalars[v] == " " || scalars[v] == "\t" { v += 1 }
            let valueColumn = v + 1

            // LOSSY key semantics: re-lex the raw spelling with the projection's
            // finisher (escapes stay literal), not the DOM's decoded `e.key`.
            let keyText = String(String.UnicodeScalarView(scalars[0..<eq]))
            let keyParts = splitDottedPath(keyText.trimmingCharacters(in: .whitespaces))

            // M1 value grammar. A triple-quoted string SPELLING anywhere in
            // the value is out of grammar (like a datetime) — and past it the
            // naive scalar-replay and lex quote models disagree, so
            // garbage-tolerating would silently misparse. Reject up front.
            var valueText = e.valueText
            if containsMultilineStringSpelling(valueText) {
                throw ParseError(line: line, message: "unrecognised value '\(valueText)'")
            }
            // Only a multi-line ARRAY may span physical lines (a line-broken
            // inline table etc. is out of grammar). The test is "\n" ONLY: a
            // LONE raw CR is not a line terminator — it flows to the decode,
            // which tolerates it as the shared scalar grammar always has.
            if valueText.unicodeScalars.contains("\n") {
                guard valueText.hasPrefix("[") else {
                    throw ParseError(line: line, message: "unrecognised value '\(valueText)'")
                }
                valueText = try normalizedMultilineArrayValue(valueText, line: line)
            }
            // Whole-value replay: any spelling the shared scalar grammar
            // cannot consume as ONE value throws here — never a silent
            // partial parse.
            guard let value = decodeWholeScalar(valueText) else {
                throw ParseError(line: line, message: "unrecognised value '\(valueText)'")
            }

            if inAoT {
                writeIntoArrayOfTablesRow(&tree, path: blockPath, key: keyParts, value: value)
            } else {
                write(&tree, path: blockPath + keyParts, value: value)
            }
            entrySpans[attributedPath(blockPath + keyParts)] = EntrySpans(
                key: SourceSpan(line: line, column: keyColumn),
                value: SourceSpan(line: line, column: valueColumn)
            )
            advance(e.raw)
        }

        advance(dom.leading)                       // BOM + pragma + file header
        for e in dom.root.entries {
            try foldEntry(e, blockPath: [], inAoT: false)
        }
        advance(dom.root.trailing)

        for block in dom.blocks {
            advance(block.leading)
            let headerLine = currentLine()
            let headerText = lexLines(block.headerRaw).first?.text ?? ""
            let headerColumn = leadingColumn(headerText)

            // LOSSY header path, same finisher as the entry keys. The bracket
            // shape is already tiler-validated, so dropping the delimiters of
            // the comment-stripped, trimmed line is safe.
            let code = lexStripComment(headerText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let inner: String
            switch block.kind {
            case .arrayElement: inner = String(code.dropFirst(2).dropLast(2))
            case .table:        inner = String(code.dropFirst().dropLast())
            }
            let path = splitDottedPath(inner.trimmingCharacters(in: .whitespaces))
            let span = SourceSpan(line: headerLine, column: headerColumn)

            if case .arrayElement = block.kind {
                appendArrayOfTablesRow(&tree, path: path, span: span)
            }
            headerSpans[attributedPath(path)] = span
            advance(block.headerRaw)

            for e in block.body.entries {
                try foldEntry(e, blockPath: path, inAoT: block.kind == .arrayElement)
            }
            advance(block.body.trailing)
        }

        return SpannedTree(tree: tree, entrySpans: entrySpans, headerSpans: headerSpans)
    }
}

// MARK: - Fold-internal value helpers

extension Toml {

    /// Whether a value spelling contains a triple-quoted (`"""` / `'''`)
    /// string — the multi-line string grammar the M1 projection excludes.
    /// Everything past such an opener is where a naive quote model and
    /// `lexScanQuoted` can disagree, so the fold rejects it up front.
    static func containsMultilineStringSpelling(_ s: String) -> Bool {
        let a = Array(s.unicodeScalars)
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "\"" || c == "'" {
                let (next, _, multiline) = lexScanQuoted(a, i)
                if multiline { return true }
                i = max(next, i + 1)
                continue
            }
            i += 1
        }
        return false
    }

    /// Prepare a multi-line ARRAY value for the scalar-grammar replay:
    /// normalize CRLF terminators to LF — only OUTSIDE string spans, so string
    /// content is never rewritten — and throw on a raw CR left INSIDE a string
    /// span (invalid TOML that the retired scanner's one-line CRLF fold
    /// garbage-tolerated; the replay cannot reproduce that output, so failing
    /// loudly beats silently misparsing).
    static func normalizedMultilineArrayValue(_ s: String, line: Int) throws -> String {
        let a = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "\"" || c == "'" {
                let (next, _, _) = lexScanQuoted(a, i)
                let end = min(max(next, i + 1), a.count)
                if a[i..<end].contains("\r") {
                    throw ParseError(line: line, message: "unrecognised value '\(s)'")
                }
                out.append(contentsOf: a[i..<end])
                i = end
                continue
            }
            if c == "\r", i + 1 < a.count, a[i + 1] == "\n" {
                out.append("\n")
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// Decode a value spelling through the shared scalar grammar, requiring
    /// the replay to consume it WHOLE: `parseFlat` parses `__v__ = <text>`, and
    /// anything in the synthetic document beyond that single binding means the
    /// naive model closed the value early (an out-of-grammar spelling) — nil,
    /// so the fold throws instead of silently dropping the over-consumed tail.
    /// (`decodeScalar` — `Annotated.Entry.value`'s lenient sibling — has no
    /// wholeness requirement; the fold deliberately does.)
    static func decodeWholeScalar(_ text: String) -> Toml.Value? {
        let doc = Toml.parseFlat("__v__ = \(text)")
        guard doc.arrays.isEmpty,
              doc.tables.count == 1,
              let root = doc.tables[""],
              root.count == 1
        else { return nil }
        return root["__v__"]
    }
}
