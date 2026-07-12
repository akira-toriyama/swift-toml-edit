// parseWithSpans — the lossy nested `parse`, RE-DERIVED from the lossless
// `Annotated` DOM, with per-entry / per-header source locations (chord#159).
//
// This is the post-M2 unification the module gated on the lossless parser
// passing full toml-test (it does — CI runs the official suite): instead of a
// second line-based scan, tile the document with `Annotated(parsing:)` and
// FOLD the DOM into the same nested `[String: Value]` tree `parse` builds,
// using the SAME proven write helpers (`write` / `appendArrayOfTablesRow` /
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
// Equivalence with the line-based `parse` — same tree (Row.spans included) or
// both throw — is CI-gated over the family's real configs, a hand corpus and
// the shared fuzz grammar (ParseWithSpansTests). The deliberate deltas, each
// pinned by a test, are all in the correct-TOML direction:
//   • CRLF documents parse correctly here (multi-line arrays included), while
//     `parse`'s Character-based `split(separator: "\n")` folds "\r\n" into one
//     Character, sees a one-line document and throws;
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

    /// `parseWithSpans`'s result: the exact `parse` tree, plus the location
    /// index the tree itself cannot carry (its Equatable identity must stay
    /// comparable with `parse`'s output — the unification gate depends on it).
    struct SpannedTree: Sendable, Equatable {
        /// The nested root — identical to `Toml.parse(source)`.
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

            // M1 value grammar: only a multi-line ARRAY may span physical
            // lines. Any other multi-line spelling (a real `"""…"""` string, a
            // line-broken inline table) is outside the projection's grammar —
            // the line-based `parse` rejected those too.
            var valueText = e.valueText
            if valueText.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
                guard valueText.hasPrefix("[") else {
                    throw ParseError(line: line, message: "unrecognised value '\(valueText)'")
                }
                // A multi-line array's interior CRLF terminators must become
                // LF before the decode: `decodeScalar` re-joins lines through
                // `parseFlat`, whose Character-based split cannot see "\r\n".
                // Safe: a raw CR-LF inside a value source is always a line
                // terminator (single-line strings cannot cross lines, and an
                // escaped `\r` is a backslash+r character pair, not a raw CR).
                valueText = valueText.replacingOccurrences(of: "\r\n", with: "\n")
            }
            guard let value = decodeScalar(valueText) else {
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
