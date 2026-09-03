// The lossless, STRICT parser that builds `Toml.Annotated` from source while
// preserving every byte. It tiles the source into trivia + content spans so
// that `render()` concatenates back to the original (the round-trip invariant).
//
// STRICT (unlike the lenient lossy `parseFlat`): a malformed header / missing
// `=` throws `Toml.ParseError`. The lenient "skip the bad line" behaviour the
// daemon relies on lives in the LOSSY PROJECTION, not here — a format-preserving
// editor must understand the whole document, not silently drop part of it.
//
// Multi-line constructs (arrays, inline tables, multi-line basic / literal
// strings) span physical lines: a value is consumed line-by-line until it
// closes (`Toml.lexValueOpen` and the shared string-aware scanners in
// Lexer.swift). The tiler is concerned with STRUCTURE and byte-faithful
// round-trip only; VALUE validity (a malformed number, a reserved escape, a
// bad datetime) is the strict decode layer's job — an invalid value still
// tiles here and is rejected on decode.

import Foundation

public extension Toml.Annotated {

    /// Parse `source` into a lossless DOM. Throws `Toml.ParseError` on a
    /// malformed header or a content line without `=`.
    init(parsing source: String) throws {
        // A single optional leading UTF-8 BOM (U+FEFF) at the very start is
        // tolerated and parked in the document `leading` so it round-trips
        // byte-identically and does not corrupt the first key. Only at offset 0
        // — a BOM mid-document is a real (invalid) character.
        var src = source
        var bom = ""
        if src.unicodeScalars.first == "\u{FEFF}" {
            bom = "\u{FEFF}"
            src.unicodeScalars.removeFirst()
        }
        let lines = Toml.lexLines(src)

        var leading = ""
        var sawContent = false
        var root = Body()
        var blocks: [Block] = []
        var pending = ""

        func appendEntry(_ e: Entry) {
            if blocks.isEmpty { root.entries.append(e) }
            else { blocks[blocks.count - 1].body.entries.append(e) }
        }

        func appendTrailing(_ s: String) {
            guard !s.isEmpty else { return }
            if blocks.isEmpty { root.trailing += s }
            else { blocks[blocks.count - 1].body.trailing += s }
        }

        // All pending trivia becomes the entry's leading — entries are never
        // reordered, so no separator / banner split is needed. The first
        // content token of the document sends its pending to the document
        // `leading` instead (pragma / file header — never moves).
        func takeEntryLeading() -> String {
            defer { pending = "" }
            if !sawContent { leading = pending; sawContent = true; return "" }
            return pending
        }

        // Headers DO move, so pending is split: blank-line SEPARATORS stay
        // with the PREVIOUS block (its body.trailing) and only the comment
        // BANNER directly above this header becomes its leading. Reorder /
        // delete then carry each element's own banner while the separators
        // stay uniform (the wand#129 rule). Round-trip is unaffected — render
        // concatenates trailing + leading in source order wherever the split
        // falls.
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

            if trimmed.isEmpty {
                pending += text + term
                continue
            }

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

            let codeScalars = Array(code.unicodeScalars)
            guard let eqOffset = Toml.lexFindEq(codeScalars) else {
                throw Toml.ParseError(line: lineNo, message: "expected '=' in '\(trimmed)'")
            }
            let keyText = String(String.UnicodeScalarView(codeScalars[0..<eqOffset]))
            let key = try Toml.lexDottedPathStrict(keyText, line: lineNo)

            // Slicing `raw` by an offset found in `code` is sound because
            // comment-stripping only removes a suffix, so the two share every
            // scalar up to the value. Continuation lines are consumed VERBATIM
            // into `raw` — round-trip is byte-exact.
            var raw = text + term
            let valueStart = eqOffset + 1
            func valueSource() -> [Unicode.Scalar] {
                Array(raw.unicodeScalars.dropFirst(valueStart))
            }
            while Toml.lexValueOpen(valueSource()) && i < lines.count {
                let (ctext, cterm) = lines[i]
                // Inside an open multi-line string a `#` is string body (the
                // decoder validates it), so comment validation applies only
                // to continuation lines that are code.
                if !Toml.lexInOpenMultilineString(valueSource()) {
                    try Toml.lexValidateComment(ctext, line: i + 1)
                }
                i += 1
                raw += ctext + cterm
            }
            let valueText = Toml.lexValueText(valueSource())
            appendEntry(Entry(leading: takeEntryLeading(), raw: raw, key: key, valueText: valueText))
        }

        // Trivia left at EOF is not split — nothing follows it.
        if !sawContent { leading = pending }
        else { appendTrailing(pending) }

        self.init(leading: bom + leading, root: root, blocks: blocks)
    }
}

// MARK: - Lossless-parser helpers (internal)
//
// Line splitting, trivia attribution and dotted-key lexing for the lossless
// DOM. The string-aware scanners these build on live in Lexer.swift.

extension Toml {

    /// Split into physical lines preserving exact terminators ("\n", "\r\n",
    /// or "" for a final line without a trailing newline), so that the
    /// concatenation of every `text + term` reproduces the source
    /// byte-for-byte. Scans Unicode scalars because Swift folds "\r\n" into
    /// one Character, which would hide the CR.
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
        if lastBlank < 0 { return ("", pending) }
        var trailing = "", banner = ""
        for (idx, line) in lines.enumerated() {
            if idx <= lastBlank { trailing += line.text + line.term }
            else { banner += line.text + line.term }
        }
        return (trailing, banner)
    }

    /// The LOSSLESS dotted-path finisher: same scan loop as the lossy
    /// `splitDottedPath`, but each segment's basic-string escapes are DECODED,
    /// so a quoted key and its decoded form are one identity for DOM lookup.
    /// Keep the two finishers distinct — see `scanDottedSegments`.
    static func lexDottedPath(_ s: String) -> [String] {
        Toml.scanDottedSegments(s).map { Toml.lexUnquoteKey($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func lexUnquoteKey(_ raw: String) -> String {
        Toml.decodeKeySegment(raw)
    }

    /// Decode a value's raw spelling into the lossy `Toml.Value` on demand
    /// (`Annotated.Entry.value`). Routes through `parseFlat` so it can never
    /// drift from the lossy grammar; nil for spellings outside it.
    static func decodeScalar(_ text: String) -> Toml.Value? {
        // The tiler hands multi-line string spellings to `valueText`, and the
        // naive quote model would close a triple quote early and fabricate a
        // plausible fragment (`"""` reads as the string `"`) instead of
        // failing — so reject up front, as the strict fold does (t-fjr0).
        if containsMultilineStringSpelling(text) { return nil }
        return Toml.parseFlat("__v__ = \(text)").tables[""]?["__v__"]
    }
}
