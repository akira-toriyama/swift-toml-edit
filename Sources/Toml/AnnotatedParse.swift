// The lossless, STRICT parser that builds `Toml.Annotated` from source while
// preserving every byte. It tiles the source into trivia + content spans so
// that `render()` concatenates back to the original (the round-trip invariant).
//
// STRICT (unlike the lenient lossy `parseFlat`): a malformed header / missing
// `=` throws `Toml.ParseError`. The lenient "skip the bad line" behaviour the
// daemon relies on lives in the LOSSY PROJECTION, not here — a format-preserving
// editor must understand the whole document, not silently drop part of it.
//
// M1 scope: the constructs the family's six configs use. Multi-line *arrays*
// span physical lines (consumed here); multi-line *strings* (`"""`) are the M2
// gap and are not yet recognised as multi-line (they would parse as a malformed
// single line and throw — none of the family configs use them).

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

            let code = Toml.lexStripComment(text)
            let trimmed = code.trimmingCharacters(in: .whitespaces)

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
                let path = Toml.lexDottedPath(inner.trimmingCharacters(in: .whitespaces))
                let block = Block(leading: takeBlockLeading(), kind: kind,
                                  headerRaw: text + term, path: path, body: Body())
                blocks.append(block)
                continue
            }

            // --- key = value (value may open a multi-line array) ---
            guard let eq = code.firstIndex(of: "=") else {
                throw Toml.ParseError(line: lineNo, message: "expected '=' in '\(trimmed)'")
            }
            var raw = text + term
            var valuePortion = String(code[code.index(after: eq)...])
            // A value that opens brackets (`[` / `{`) without closing them on
            // this line continues onto following physical lines — consume them
            // into this entry's raw until the brackets balance (or EOF).
            while Toml.lexBracketDepth(valuePortion) > 0 && i < lines.count {
                let (ctext, cterm) = lines[i]
                i += 1
                raw += ctext + cterm
                valuePortion += " " + Toml.lexStripComment(ctext)
            }
            let keyText = String(code[..<eq]).trimmingCharacters(in: .whitespaces)
            let key = Toml.lexDottedPath(keyText)
            let valueText = valuePortion.trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - Shared lexer helpers (internal)
//
// These mirror the quote/escape-aware scanners in the lossy `Toml` parser.
// They are duplicated here deliberately for M1: once the lossless parser
// passes full toml-test, the lossy `parse` / `parseFlat` projections will be
// re-derived over this DOM and the duplication collapses (a pre-swap step).

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
        where line.text.trimmingCharacters(in: .whitespaces).isEmpty {
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

    /// Strip an unquoted `#` comment to end of line, quote- AND escape-aware
    /// (a `#` inside `"…"`/`'…'` is kept; an escaped `\"` does not close a
    /// basic string). Returns the code portion (everything before the comment).
    static func lexStripComment(_ s: String) -> String {
        var inStr = false
        var quote: Character = "\""
        var escaped = false
        var out = ""
        for c in s {
            if inStr {
                if escaped { escaped = false }
                else if c == "\\" && quote == "\"" { escaped = true }
                else if c == quote { inStr = false }
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

    /// Net `[`/`{` depth, quote- and escape-aware (brackets inside strings
    /// don't count). `> 0` means an array / inline table is still open.
    static func lexBracketDepth(_ s: String) -> Int {
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

    /// Strip a matching surrounding quote pair from a key segment.
    static func lexUnquoteKey(_ raw: String) -> String {
        if raw.count >= 2 {
            let f = raw.first!, l = raw.last!
            if (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                return String(raw.dropFirst().dropLast())
            }
        }
        return raw
    }

    /// Decode a value's raw spelling into the lossy `Toml.Value` on demand
    /// (used by `Annotated.Entry.value`). Reuses the proven lossy grammar by
    /// round-tripping through `parseFlat`, so it can never drift from it.
    /// Returns nil for spellings outside the M1 scalar grammar.
    static func decodeScalar(_ text: String) -> Toml.Value? {
        Toml.parseFlat("__v__ = \(text)").tables[""]?["__v__"]
    }
}
