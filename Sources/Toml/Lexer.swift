// Shared, string-aware lexer primitives for the lossless parser.
//
// Every scanner — comment-stripping, value-continuation, `=` finding, typed
// decoding — gets ONE shared notion of where a string starts and ends,
// single- AND triple-quoted, basic AND literal (`lexScanQuoted`), so they can
// never disagree about string boundaries. A scanner that only tracks bracket
// balance cannot see a multi-line string: its body lines get re-classified
// as phantom headers / key=values, and a DOM can round-trip byte-identically
// while being structurally wrong.
//
// All scanners work on `[Unicode.Scalar]` (not `Character`) so they compose
// with `lexLines`' scalar model and a CRLF folded into one `Character` can't
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
                if basic && c == "\\" { j += 2; continue }   // an escape may span "\n" (line-ending backslash)
                if c == q {
                    var run = 0
                    while j + run < a.count && a[j + run] == q { run += 1 }
                    if run >= 3 {
                        let content = min(run - 3, 2)         // trailing-quote rule
                        return (j + content + 3, true, true)
                    }
                    j += run
                    continue
                }
                j += 1
            }
            return (a.count, false, true)
        } else {
            var j = i + 1
            while j < a.count {
                let c = a[j]
                if c == "\n" { return (j, false, false) }
                if basic && c == "\\" { j += 2; continue }
                if c == q { return (j + 1, true, false) }
                j += 1
            }
            return (a.count, false, false)
        }
    }

    /// Whether the accumulated value source ENDS inside an unterminated
    /// multi-line string — the next physical line is then string body, not
    /// code, so a `#` on it must not be comment-validated.
    static func lexInOpenMultilineString(_ a: [Unicode.Scalar]) -> Bool {
        var i = 0
        while i < a.count {
            let c = a[i]
            if c == "#" { while i < a.count && a[i] != "\n" { i += 1 }; continue }
            if c == "\"" || c == "'" {
                let (next, closed, multiline) = lexScanQuoted(a, i)
                if multiline && !closed { return true }
                i = next
                continue
            }
            i += 1
        }
        return false
    }

    /// Whether a value's accumulated source is still OPEN — the tiler must
    /// pull another physical line: a `[`/`{` is unbalanced OR a multi-line
    /// string is unterminated. A single-line string never extends a value
    /// across a newline; that is what makes an unterminated one throw
    /// instead of swallowing the next line.
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
                if multiline && !closed { return true }
                i = next
                continue
            }
            if c == "[" || c == "{" { depth += 1 }
            else if c == "]" || c == "}" { depth -= 1 }
            i += 1
        }
        return depth > 0
    }

    /// The key/value separator: the first `=` OUTSIDE any string, so an `=`
    /// inside a quoted key (`"a=b" = 1`) is not mistaken for it.
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

    /// Strip an inline `#` comment, string-aware. A `#` inside an OPEN
    /// multi-line string is preserved too: the close is on a later line, so
    /// the whole remainder is string interior.
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

    /// TOML 1.0 forbids raw control characters other than tab (U+0000–08,
    /// U+000A–1F, U+007F) in a comment. String-aware so a `#` inside a string
    /// is not treated as a comment.
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
                    if v == 0x09 { continue }
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

    /// `Entry.valueText`: the value source with inline `#` comments removed
    /// (string-aware) and the edges trimmed. Interior newlines are KEPT so a
    /// multi-line array / string reaches the decode layer intact.
    static func lexValueText(_ a: [Unicode.Scalar]) -> String {
        var i = 0
        var out = String.UnicodeScalarView()
        while i < a.count {
            let c = a[i]
            if c == "#" {
                while i < a.count && a[i] != "\n" { i += 1 }
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
        // NOT `.whitespacesAndNewlines`: it would also strip U+000B / U+000C,
        // masking a raw vertical-tab / form-feed the strict decoder must see
        // (e.g. `1\u{0B}`) and reject on its trailing-character check.
        return Toml.asciiTrim(String(out))
    }

    /// Trim the whitespace / line-terminator edges of a VALUE source — but
    /// NOT a trailing LONE CR. A CRLF terminator's CR is stripped (its LF
    /// precedes it here), whereas a bare CR is an invalid control char that
    /// must survive to the strict decoder; stripping it would silently accept
    /// `a = 1\r`.
    static func asciiTrim(_ s: String) -> String {
        var a = Array(s.unicodeScalars)
        while let f = a.first, f == " " || f == "\t" || f == "\n" || f == "\r" { a.removeFirst() }
        trailing: while let l = a.last {
            switch l {
            case " ", "\t": a.removeLast()
            case "\n":
                a.removeLast()
                if a.last == "\r" { a.removeLast() }
            default: break trailing
            }
        }
        return String(String.UnicodeScalarView(a))
    }

    /// Trim ASCII space and tab ONLY — the exact TOML inline whitespace set.
    /// For blank-line / header classification: a CR or LF surviving in a
    /// physical line's text (`lexLines` strips the real terminator) is a
    /// STRAY control char, so the line must NOT count as blank.
    static func asciiSpaceTrim(_ s: String) -> String {
        var a = Array(s.unicodeScalars)
        while let f = a.first, f == " " || f == "\t" { a.removeFirst() }
        while let l = a.last, l == " " || l == "\t" { a.removeLast() }
        return String(String.UnicodeScalarView(a))
    }

    /// The conformance-grade key grammar (TOML 1.0): a bare key is ASCII
    /// `[A-Za-z0-9_-]+`, a quoted key is a SINGLE-line basic / literal string
    /// (escapes decoded for basic), and nothing else. Throws on an empty
    /// segment (`.`, `a.`, `a..b`), a disallowed bare-key character, a
    /// multi-line key, trailing junk after a quoted segment, or a bad escape.
    /// The lenient `lexDottedPath` remains for library-side lookups, where a
    /// caller-supplied key must not throw.
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
