// Shared, string-aware lexer primitives for the lossless parser.
//
// The M1 tiler classified each physical line independently and only continued a
// value across lines when `[`/`{` brackets were unbalanced. That model cannot
// see a multi-line string: a value opening `"""`/`'''` leaves the string open
// across the newline, but the M1 scanner has no concept of a triple-quote, so
// the body lines were re-classified as phantom headers / key=values (or threw
// `expected '='`). These primitives give every scanner ONE shared notion of
// where a string starts and ends — single- AND triple-quoted, basic AND literal
// — so comment-stripping, value-continuation and (later) typed decoding can
// never disagree about string boundaries.
//
// All scanners work on `[Unicode.Scalar]` (not `Character`) so they compose
// with `lexLines`' scalar model and so a CRLF folded into one `Character` can't
// hide a boundary.

import Foundation

extension Toml {

    /// Scan a quoted string whose opening delimiter starts at `a[i]` (`"` or
    /// `'`). Detects single vs triple and basic (`"`) vs literal (`'`), and
    /// scans to the matching close, returning:
    ///   - `next`: the scalar index just past the closing delimiter (or
    ///     `a.count` if the string runs off the end of `a`).
    ///   - `closed`: whether the close was found within `a`.
    ///   - `multiline`: whether this was a triple-quoted string (the only kind
    ///     that may legally span physical lines).
    ///
    /// Rules honoured (TOML 1.0):
    ///   - Basic strings process `\` escapes (so `\"` is not a delimiter quote,
    ///     and a line-ending `\` in a multi-line basic string folds the newline)
    ///     — literal strings do not.
    ///   - A single-line string (`"`/`'`) never crosses a newline: if one is
    ///     reached first, the scan stops there with `closed == false`.
    ///   - The "up to two trailing quotes" rule: a multi-line string may end
    ///     with one or two quote characters immediately before the closing
    ///     triple (`"""he said ""..."""`), so the close is the END of a run of
    ///     ≥3 quotes, with the leading (run−3, capped at 2) quotes kept as
    ///     content.
    static func lexScanQuoted(_ a: [Unicode.Scalar], _ i: Int)
        -> (next: Int, closed: Bool, multiline: Bool)
    {
        let q = a[i]
        let basic = (q == "\"")
        let triple = i + 2 < a.count && a[i + 1] == q && a[i + 2] == q

        if triple {
            var j = i + 3
            while j < a.count {
                let c = a[j]
                if basic && c == "\\" { j += 2; continue }   // escape: skip next scalar (across \n)
                if c == q {
                    var run = 0
                    while j + run < a.count && a[j + run] == q { run += 1 }
                    if run >= 3 {
                        let content = min(run - 3, 2)         // trailing-quote rule
                        return (j + content + 3, true, true)
                    }
                    j += run                                 // <3 quotes → content
                    continue
                }
                j += 1
            }
            return (a.count, false, true)                    // unterminated multi-line string
        } else {
            var j = i + 1
            while j < a.count {
                let c = a[j]
                if c == "\n" { return (j, false, false) }    // single-line: never crosses \n
                if basic && c == "\\" { j += 2; continue }
                if c == q { return (j + 1, true, false) }
                j += 1
            }
            return (a.count, false, false)                   // unterminated single-line string
        }
    }

    /// Whether a value's accumulated source (which may already span physical
    /// lines, newlines included) is still OPEN — i.e. the parser must pull
    /// another physical line. Open while a `[`/`{` is unbalanced OR a multi-line
    /// string is unterminated. `#` outside a string begins a comment to the end
    /// of its line. Single-line strings never extend the value across a newline.
    static func lexValueOpen(_ a: [Unicode.Scalar]) -> Bool {
        var i = 0, depth = 0
        while i < a.count {
            let c = a[i]
            if c == "#" {
                while i < a.count && a[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" || c == "'" {
                let (next, closed, multiline) = lexScanQuoted(a, i)
                if multiline && !closed { return true }      // open triple-quoted string
                i = next
                continue
            }
            if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
            i += 1
        }
        return depth > 0
    }

    /// Index of the `=` that separates a key from its value — the first `=` that
    /// is OUTSIDE any string (so an `=` inside a quoted key like `"a=b" = 1`, or
    /// inside the value, is skipped). Returns nil if there is no such `=`.
    static func lexFindEq(_ a: [Unicode.Scalar]) -> Int? {
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "\"" || c == "'" {
                let (next, _, _) = lexScanQuoted(a, i)
                i = next
                continue
            }
            if c == "=" { return i }
            i += 1
        }
        return nil
    }

    /// Strip an inline `#` comment, string-aware (single- and triple-quoted).
    /// Everything from the first `#` that is outside a string to end of line is
    /// removed; a `#` inside any string (incl. a multi-line string body, where
    /// the close is on a later line so the whole remainder is string interior)
    /// is preserved. Used to classify the FIRST line of a construct.
    static func lexStripComment(_ s: String) -> String {
        let a = Array(s.unicodeScalars)
        var i = 0
        var out = String.UnicodeScalarView()
        while i < a.count {
            let c = a[i]
            if c == "#" { break }
            if c == "\"" || c == "'" {
                let (next, _, _) = lexScanQuoted(a, i)
                let end = min(next, a.count)
                out.append(contentsOf: a[i..<end])
                i = next
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// Validate that a line's `#` comment (if any) contains no raw control
    /// characters other than tab — TOML 1.0 forbids control chars (U+0000–08,
    /// U+000A–1F, U+007F) in comments. String-aware so a `#` inside a string is
    /// not treated as a comment. Throws `Toml.ParseError` on a bad byte.
    static func lexValidateComment(_ s: String, line: Int) throws {
        let a = Array(s.unicodeScalars)
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "\"" || c == "'" {
                let (next, _, _) = lexScanQuoted(a, i)
                i = next
                continue
            }
            if c == "#" {
                for j in (i + 1)..<a.count {
                    let v = a[j].value
                    if v == 0x09 { continue }                  // tab allowed
                    if v <= 0x08 || (v >= 0x0A && v <= 0x1F) || v == 0x7F {
                        throw Toml.ParseError(line: line,
                            message: "control character U+\(String(format: "%04X", v)) in comment")
                    }
                }
                return
            }
            i += 1
        }
    }

    /// The value text the lossy decode reads: the value source with inline `#`
    /// comments removed (string-aware, per physical line) but interior newlines
    /// and string bodies preserved, then whitespace-trimmed. Newlines are kept
    /// so a multi-line array/string survives to the decode layer intact.
    static func lexValueText(_ a: [Unicode.Scalar]) -> String {
        var i = 0
        var out = String.UnicodeScalarView()
        while i < a.count {
            let c = a[i]
            if c == "#" {
                while i < a.count && a[i] != "\n" { i += 1 }  // drop comment, keep the newline
                continue
            }
            if c == "\"" || c == "'" {
                let (next, _, _) = lexScanQuoted(a, i)
                let end = min(next, a.count)
                out.append(contentsOf: a[i..<end])
                i = next
                continue
            }
            out.append(c)
            i += 1
        }
        // Trim only ASCII space / tab / newline — NOT U+000B/U+000C, which
        // `.whitespacesAndNewlines` would also strip, masking a raw vertical-tab
        // / form-feed control char that TOML forbids (the strict decoder must
        // see e.g. `1\u{0B}` and reject it on the trailing-character check).
        return Toml.asciiTrim(String(out))
    }

    /// Trim leading/trailing ASCII space, tab, CR and LF only.
    static func asciiTrim(_ s: String) -> String {
        var a = Array(s.unicodeScalars)
        while let f = a.first, f == " " || f == "\t" || f == "\n" || f == "\r" { a.removeFirst() }
        while let l = a.last, l == " " || l == "\t" || l == "\n" || l == "\r" { a.removeLast() }
        return String(String.UnicodeScalarView(a))
    }

    /// Strict dotted-key / header-path parse: split on top-level dots
    /// (string-aware), then validate AND decode each segment — a bare key is
    /// ASCII `[A-Za-z0-9_-]+`, a quoted key is a SINGLE-line basic/literal
    /// string (escapes decoded for basic), and nothing else. Throws on an empty
    /// segment (`.`, `a.`, `a..b`), a bare key with a disallowed character, a
    /// multi-line (`"""`) key, trailing junk after a quoted segment, or a bad
    /// escape. This is the conformance-grade key grammar; the lenient
    /// `lexDottedPath` remains for library-side lookups.
    static func lexDottedPathStrict(_ s: String, line: Int) throws -> [String] {
        let a = Array(s.unicodeScalars)
        var rawSegs: [[Unicode.Scalar]] = []
        var cur: [Unicode.Scalar] = []
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "\"" || c == "'" {
                let (next, closed, _) = lexScanQuoted(a, i)
                guard closed else { throw Toml.ParseError(line: line, message: "unterminated quoted key") }
                cur.append(contentsOf: a[i..<next])
                i = next
                continue
            }
            if c == "." { rawSegs.append(cur); cur = []; i += 1; continue }
            cur.append(c)
            i += 1
        }
        rawSegs.append(cur)
        return try rawSegs.map { try validateKeySegment($0, line: line) }
    }

    private static func validateKeySegment(_ seg: [Unicode.Scalar], line: Int) throws -> String {
        var s = seg
        while let f = s.first, f == " " || f == "\t" { s.removeFirst() }
        while let l = s.last, l == " " || l == "\t" { s.removeLast() }
        guard !s.isEmpty else { throw Toml.ParseError(line: line, message: "empty key") }
        let q = s[0]
        if q == "\"" || q == "'" {
            if s.count >= 3 && s[1] == q && s[2] == q {
                throw Toml.ParseError(line: line, message: "multi-line string keys are not allowed")
            }
            let (next, closed, multiline) = lexScanQuoted(s, 0)
            guard closed, !multiline else { throw Toml.ParseError(line: line, message: "invalid quoted key") }
            guard next == s.count else {
                throw Toml.ParseError(line: line, message: "unexpected content after quoted key")
            }
            let body = Array(s[1..<(s.count - 1)])
            let p = StrictParser([], line: line)
            return q == "\"" ? try p.decodeBasic(body, multiline: false)
                             : try p.decodeLiteral(body, multiline: false)
        }
        for c in s {
            let ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
                || (c >= "0" && c <= "9") || c == "_" || c == "-"
            guard ok else {
                throw Toml.ParseError(line: line, message: "invalid character in bare key '\(Character(c))'")
            }
        }
        return String(String.UnicodeScalarView(s))
    }
}
