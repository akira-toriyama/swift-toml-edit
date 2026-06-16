// The lossless, STRICT parser that builds `Toml.Annotated` from source while
// preserving every byte. It tiles the source into trivia + content spans so
// that `render()` concatenates back to the original (the round-trip invariant).
//
// STRICT (unlike the lenient lossy `parseFlat`): a malformed header / missing
// `=` throws `Toml.ParseError`. The lenient "skip the bad line" behaviour the
// daemon relies on lives in the LOSSY PROJECTION, not here — a format-preserving
// editor must understand the whole document, not silently drop part of it.
//
// Multi-line constructs (arrays, inline tables, and — since M2 step 1 —
// multi-line basic/literal strings `"""`/`'''`) span physical lines: a value
// is consumed line-by-line until it closes (see `Toml.lexValueOpen` and the
// shared string-aware scanners in Lexer.swift). The tiler is concerned with
// STRUCTURE and byte-faithful round-trip; VALUE validity (a malformed number,
// a reserved escape, a bad datetime) is the strict decode layer's job, not the
// tiler's — so an invalid value still tiles here and is rejected on decode.

import Foundation

public extension Toml.Annotated {

    /// Parse `source` into a lossless DOM. Throws `Toml.ParseError` on a
    /// malformed header or a content line without `=`.
    init(parsing source: String) throws {
        let lines = Toml.lexLines(source)

        var leading = ""                  // doc-level leading (before first content)
        var sawContent = false
        var root = Body()
        var blocks: [Block] = []
        var pending = ""                  // trivia accumulated since last content

        func appendEntry(_ e: Entry) {
            if blocks.isEmpty { root.entries.append(e) }
            else { blocks[blocks.count - 1].body.entries.append(e) }
        }

        // Append trailing trivia to whichever body is currently open (the
        // root, or the last block's body).
        func appendTrailing(_ s: String) {
            guard !s.isEmpty else { return }
            if blocks.isEmpty { root.trailing += s }
            else { blocks[blocks.count - 1].body.trailing += s }
        }

        // For a key/value: all pending trivia becomes its leading (entries are
        // not reordered, so no split is needed). The first content token sends
        // its pending to the document `leading` (pragma / file header — never
        // moves).
        func takeEntryLeading() -> String {
            defer { pending = "" }
            if !sawContent { leading = pending; sawContent = true; return "" }
            return pending
        }

        // For a header: split pending so blank-line SEPARATORS stay with the
        // PREVIOUS block (as its body.trailing) and only the comment BANNER
        // immediately above this header becomes its leading. That way
        // reorder / delete carry each element's own banner while the blank-line
        // separators stay uniform (the wand#129 rule, refined for clean edits).
        // Round-trip is unaffected — render concatenates trailing + leading in
        // source order regardless of where the split falls.
        func takeBlockLeading() -> String {
            defer { pending = "" }
            if !sawContent { leading = pending; sawContent = true; return "" }
            let (trailing, banner) = Toml.splitTrivia(pending)
            appendTrailing(trailing)
            return banner
        }

        var i = 0
        while i < lines.count {
            let (text, term) = lines[i]
            let lineNo = i + 1
            i += 1

            try Toml.lexValidateComment(text, line: lineNo)
            let code = Toml.lexStripComment(text)
            // Trim only ASCII space/tab (the TOML whitespace set): a line made
            // solely of NON-ASCII Unicode whitespace (U+00A0, U+3000, …) or a
            // stray CR is NOT blank — it must fall through and be rejected, not
            // swallowed as trivia (Foundation's `.whitespaces` strips the former,
            // `.whitespacesAndNewlines` the latter).
            let trimmed = Toml.asciiSpaceTrim(code)

            // --- trivia: blank line or comment-only line ---
            if trimmed.isEmpty {
                pending += text + term
                continue
            }

            // --- table / array-of-tables header ---
            if trimmed.hasPrefix("[") {
                let kind: Block.Kind
                let inner: Substring
                if trimmed.hasPrefix("[[") {
                    guard trimmed.hasSuffix("]]") else {
                        throw Toml.ParseError(line: lineNo, message: "unterminated [[...]] header")
                    }
                    kind = .arrayElement
                    inner = trimmed.dropFirst(2).dropLast(2)
                } else {
                    guard trimmed.hasSuffix("]") else {
                        throw Toml.ParseError(line: lineNo, message: "unterminated [...] header")
                    }
                    kind = .table
                    inner = trimmed.dropFirst().dropLast()
                }
                let path = try Toml.lexDottedPathStrict(String(inner), line: lineNo)
                let block = Block(leading: takeBlockLeading(), kind: kind,
                                  headerRaw: text + term, path: path, body: Body())
                blocks.append(block)
                continue
            }

            // --- key = value (value may span lines: multi-line array, inline
            //     table, or multi-line string) ---
            let codeScalars = Array(code.unicodeScalars)
            guard let eqOffset = Toml.lexFindEq(codeScalars) else {
                throw Toml.ParseError(line: lineNo, message: "expected '=' in '\(trimmed)'")
            }
            let keyText = String(String.UnicodeScalarView(codeScalars[0..<eqOffset]))
            let key = try Toml.lexDottedPathStrict(keyText, line: lineNo)

            // The value source is everything in `raw` after the `=`. `code`'s
            // prefix up to the value equals `raw`'s (comment-stripping only
            // touches the trailing comment, which is after the value), so we can
            // slice `raw` by scalar offset. A value that leaves brackets open OR
            // a multi-line string unterminated continues onto following physical
            // lines — consume them VERBATIM into `raw` (round-trip is byte-exact)
            // until the value closes (or EOF).
            var raw = text + term
            let valueStart = eqOffset + 1
            func valueSource() -> [Unicode.Scalar] {
                Array(raw.unicodeScalars.dropFirst(valueStart))
            }
            while Toml.lexValueOpen(valueSource()) && i < lines.count {
                let (ctext, cterm) = lines[i]
                // Validate a continuation line's comment for control chars too —
                // but ONLY when this line is code (a multi-line array / inline
                // table), not the interior of an open multi-line string (where a
                // `#` is string body, validated by the decoder).
                if !Toml.lexInOpenMultilineString(valueSource()) {
                    try Toml.lexValidateComment(ctext, line: i + 1)
                }
                i += 1
                raw += ctext + cterm
            }
            let valueText = Toml.lexValueText(valueSource())
            appendEntry(Entry(leading: takeEntryLeading(), raw: raw, key: key, valueText: valueText))
        }

        // Trivia left at EOF: the document's leading (if there was no content
        // at all) or the trailing of the final body. Nothing follows it, so it
        // is not split.
        if !sawContent { leading = pending }
        else { appendTrailing(pending) }

        self.init(leading: leading, root: root, blocks: blocks)
    }
}

// MARK: - Lossless-parser helpers (internal)
//
// Line splitting, trivia attribution and dotted-key lexing for the lossless
// DOM. The string-aware scanners these build on (`lexScanQuoted`,
// `lexValueOpen`, `lexStripComment`, …) live in Lexer.swift. The lossy `Toml`
// parser keeps its own private single-char scanners for now; once the lossless
// parser passes full toml-test, `parse` / `parseFlat` will be re-derived over
// this DOM and that duplication collapses (the planned post-M2 unification).

extension Toml {

    /// Split into physical lines preserving exact terminators ("\n", "\r\n",
    /// or "" for a final line without a trailing newline). The concatenation
    /// of every `text + term` reproduces the source byte-for-byte (CRLF-safe:
    /// we scan Unicode scalars, since Swift folds "\r\n" into one Character).
    static func lexLines(_ s: String) -> [(text: String, term: String)] {
        let scalars = Array(s.unicodeScalars)
        var out: [(String, String)] = []
        var start = 0
        var j = 0

        func slice(_ lo: Int, _ hi: Int) -> String {
            var v = "".unicodeScalars
            v.append(contentsOf: scalars[lo..<hi])
            return String(v)
        }

        while j < scalars.count {
            if scalars[j] == "\n" {
                var end = j
                var term = "\n"
                if end > start && scalars[end - 1] == "\r" { end -= 1; term = "\r\n" }
                out.append((slice(start, end), term))
                start = j + 1
            }
            j += 1
        }
        if start < scalars.count { out.append((slice(start, scalars.count), "")) }
        return out
    }

    /// Split a run of trivia (the lines between two content tokens) into the
    /// part that belongs to the PRECEDING block (everything up to and
    /// including the last blank line — the separator) and the comment BANNER
    /// directly above the FOLLOWING header (the run of comment lines after the
    /// last blank, with no intervening blank). With no blank line the whole run
    /// is the banner; with no comment after the last blank the banner is empty.
    static func splitTrivia(_ pending: String) -> (trailing: String, leading: String) {
        if pending.isEmpty { return ("", "") }
        let lines = lexLines(pending)
        var lastBlank = -1
        for (idx, line) in lines.enumerated()
        where Toml.asciiSpaceTrim(line.text).isEmpty {
            lastBlank = idx
        }
        if lastBlank < 0 { return ("", pending) }   // no separator → all banner
        var trailing = "", banner = ""
        for (idx, line) in lines.enumerated() {
            if idx <= lastBlank { trailing += line.text + line.term }
            else { banner += line.text + line.term }
        }
        return (trailing, banner)
    }

    /// Split a dotted key / header on top-level dots, keeping quoted segments
    /// intact (`a."b.c"` → `["a", "b.c"]`) and unquoting each segment.
    static func lexDottedPath(_ s: String) -> [String] {
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
        return segs.map { Toml.lexUnquoteKey($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Resolve a key segment's quoting: strip a literal `'…'` pair verbatim,
    /// decode a basic `"…"` pair's escapes, leave a bare key as-is — so a quoted
    /// key and its decoded form are one identity (`Toml.decodeKeySegment`).
    static func lexUnquoteKey(_ raw: String) -> String {
        Toml.decodeKeySegment(raw)
    }

    /// Decode a value's raw spelling into the lossy `Toml.Value` on demand
    /// (used by `Annotated.Entry.value`). Reuses the proven lossy grammar by
    /// round-tripping through `parseFlat`, so it can never drift from it.
    /// Returns nil for spellings outside the M1 scalar grammar.
    static func decodeScalar(_ text: String) -> Toml.Value? {
        Toml.parseFlat("__v__ = \(text)").tables[""]?["__v__"]
    }
}
