// The strict TOML 1.0 value decoder — the conformance-grade replacement for the
// lenient M1 `decodeScalar` (which routed through the family-subset `parseFlat`
// and so could never pass toml-test). It is a recursive-descent parser over the
// value's source scalars producing a `Toml.TypedValue`, and it THROWS on every
// malformed value the official `invalid/*` corpus expects to be rejected.
//
// It operates on the already-comment-stripped, trimmed value text the lossless
// tiler captures (`Toml.lexValueText`), so there are no `#` comments to handle
// here; whitespace and newlines only separate array/inline-table elements.
// Strings reuse the shared `lexScanQuoted` scanner (Lexer.swift) so the decoder
// and the tiler agree byte-for-byte about where every string starts and ends.

import Foundation

public extension Toml {

    /// Decode a value's source text into a fully-typed `TypedValue`, throwing
    /// `Toml.ParseError` if it is not a single, valid TOML 1.0 value.
    static func decodeStrict(_ source: String, line: Int = 0) throws -> TypedValue {
        var p = StrictParser(Array(source.unicodeScalars), line: line)
        p.skipSpaces()
        let v = try p.parseValue()
        p.skipSpacesAndNewlines()
        guard p.atEnd else {
            throw ParseError(line: line, message: "trailing characters after value")
        }
        return v
    }
}

/// Internal cursor-based strict value parser.
struct StrictParser {
    let a: [Unicode.Scalar]
    var i = 0
    let line: Int

    init(_ a: [Unicode.Scalar], line: Int) { self.a = a; self.line = line }

    // MARK: cursor

    var atEnd: Bool { i >= a.count }
    func peek(_ o: Int = 0) -> Unicode.Scalar? { i + o < a.count ? a[i + o] : nil }

    func err(_ m: String) -> Toml.ParseError { Toml.ParseError(line: line, message: m) }

    mutating func skipSpaces() {
        while i < a.count, a[i] == " " || a[i] == "\t" { i += 1 }
    }
    mutating func skipSpacesAndNewlines() {
        while i < a.count, a[i] == " " || a[i] == "\t" || a[i] == "\n" || a[i] == "\r" { i += 1 }
    }

    // MARK: value dispatch

    mutating func parseValue() throws -> Toml.TypedValue {
        guard let c = peek() else { throw err("empty value") }
        switch c {
        case "\"", "'": return .string(try parseString())
        case "[":       return try parseArray()
        case "{":       return try parseInlineTable()
        case "t", "f":  return try parseBool()
        default:
            // Number or datetime. Datetimes are recognised by their leading
            // `dddd-dd-dd` (date) or `dd:dd` (time) shape; everything else is an
            // integer or float.
            if looksLikeDate() || looksLikeTime() { return try parseDateTime() }
            return try parseNumber()
        }
    }

    // MARK: bool

    mutating func parseBool() throws -> Toml.TypedValue {
        if match("true")  { return .boolean(true) }
        if match("false") { return .boolean(false) }
        throw err("invalid value (expected true/false)")
    }

    /// If the literal `s` is next, consume it and return true.
    mutating func match(_ s: String) -> Bool {
        let w = Array(s.unicodeScalars)
        guard i + w.count <= a.count else { return false }
        for k in 0..<w.count where a[i + k] != w[k] { return false }
        i += w.count
        return true
    }

    // MARK: strings

    mutating func parseString() throws -> String {
        let (next, closed, multiline) = Toml.lexScanQuoted(a, i)
        guard closed else { throw err("unterminated string") }
        let q = a[i]
        let open = multiline ? 3 : 1
        let content = Array(a[(i + open)..<(next - open)])
        i = next
        if q == "\"" { return try decodeBasic(content, multiline: multiline) }
        else         { return try decodeLiteral(content, multiline: multiline) }
    }

    /// Decode a basic-string body (escapes processed). For multi-line bodies a
    /// single leading newline is trimmed and a line-ending `\` folds following
    /// whitespace incl. newlines.
    func decodeBasic(_ raw: [Unicode.Scalar], multiline: Bool) throws -> String {
        var c = raw
        if multiline { c = trimLeadingNewline(c) }
        var out = String.UnicodeScalarView()
        var k = 0
        while k < c.count {
            let ch = c[k]
            if ch == "\\" {
                k += 1
                guard k < c.count else { throw err("dangling backslash escape") }
                let e = c[k]
                switch e {
                case "b":  out.append("\u{08}"); k += 1
                case "t":  out.append("\u{09}"); k += 1
                case "n":  out.append("\u{0A}"); k += 1
                case "f":  out.append("\u{0C}"); k += 1
                case "r":  out.append("\u{0D}"); k += 1
                case "\"": out.append("\u{22}"); k += 1
                case "\\": out.append("\u{5C}"); k += 1
                case "u":  out.append(try unicodeEscape(c, &k, digits: 4))
                case "U":  out.append(try unicodeEscape(c, &k, digits: 8))
                case " ", "\t", "\n", "\r":
                    guard multiline else { throw err("invalid escape '\\\(Character(e))'") }
                    // Line-ending backslash: only whitespace may follow before
                    // the newline; trim it and all following whitespace/newlines.
                    try foldLineEnding(c, &k)
                default:
                    throw err("invalid/reserved escape '\\\(Character(e))'")
                }
            } else {
                try validateRaw(ch, multiline: multiline)
                out.append(ch); k += 1
            }
        }
        return String(out)
    }

    /// Decode a literal-string body (verbatim, no escapes). A multi-line body
    /// trims one leading newline; raw control chars are still rejected.
    func decodeLiteral(_ raw: [Unicode.Scalar], multiline: Bool) throws -> String {
        var c = raw
        if multiline { c = trimLeadingNewline(c) }
        var out = String.UnicodeScalarView()
        for ch in c {
            try validateRaw(ch, multiline: multiline, literal: true)
            out.append(ch)
        }
        return String(out)
    }

    private func trimLeadingNewline(_ c: [Unicode.Scalar]) -> [Unicode.Scalar] {
        if c.first == "\n" { return Array(c.dropFirst()) }
        if c.first == "\r", c.count >= 2, c[1] == "\n" { return Array(c.dropFirst(2)) }
        return c
    }

    private func unicodeEscape(_ c: [Unicode.Scalar], _ k: inout Int, digits: Int) throws -> Unicode.Scalar {
        // c[k] == 'u'/'U'; consume it then `digits` hex digits.
        guard k + digits < c.count else { throw err("incomplete unicode escape") }
        var value: UInt32 = 0
        for d in 1...digits {
            guard let h = hexVal(c[k + d]) else { throw err("invalid unicode escape digit") }
            value = value &* 16 &+ UInt32(h)
        }
        k += digits + 1
        guard let s = Unicode.Scalar(value) else {
            throw err("escape is not a valid Unicode scalar (U+\(String(value, radix: 16)))")
        }
        return s
    }

    private func foldLineEnding(_ c: [Unicode.Scalar], _ k: inout Int) throws {
        // At c[k] = first whitespace/newline after the backslash. Skip spaces and
        // tabs; the run MUST reach a newline (otherwise `\ ` is a bad escape).
        var j = k
        while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
        guard j < c.count, c[j] == "\n" || c[j] == "\r" else {
            throw err("backslash must be followed by end-of-line whitespace only")
        }
        // Now skip all whitespace + newlines up to the next non-whitespace.
        while j < c.count, c[j] == " " || c[j] == "\t" || c[j] == "\n" || c[j] == "\r" { j += 1 }
        k = j
    }

    private func validateRaw(_ ch: Unicode.Scalar, multiline: Bool, literal: Bool = false) throws {
        let v = ch.value
        if v == 0x09 { return }                              // tab is always allowed
        if multiline, v == 0x0A || v == 0x0D { return }      // newlines only in multi-line
        if v <= 0x08 || (v >= 0x0A && v <= 0x1F) || v == 0x7F {
            throw err("raw control character U+\(String(format: "%04X", v)) must be escaped")
        }
    }

    // MARK: arrays

    mutating func parseArray() throws -> Toml.TypedValue {
        i += 1   // '['
        var out: [Toml.TypedValue] = []
        skipSpacesAndNewlines()
        if peek() == "]" { i += 1; return .array(out) }
        while true {
            skipSpacesAndNewlines()
            guard !atEnd else { throw err("unterminated array") }
            out.append(try parseValue())
            skipSpacesAndNewlines()
            guard let c = peek() else { throw err("unterminated array") }
            if c == "," {
                i += 1
                skipSpacesAndNewlines()
                if peek() == "]" { i += 1; return .array(out) }   // trailing comma OK
            } else if c == "]" {
                i += 1
                return .array(out)
            } else {
                throw err("expected ',' or ']' in array")
            }
        }
    }

    // MARK: inline tables (single line; newline inside is invalid)

    mutating func parseInlineTable() throws -> Toml.TypedValue {
        i += 1   // '{'
        // Build through the redefinition machine so internal conflicts
        // (`{a.b=1, a.b.c=2}`, `{b=1, b.c=2}`, duplicate keys) are rejected.
        let t = Toml.TreeTable(kind: .inline)
        skipSpaces()
        if peek() == "}" { i += 1; return t.toTyped() }
        while true {
            skipSpaces()
            if peek() == "\n" || peek() == "\r" { throw err("newline inside inline table") }
            let path = try parseKeyPath()
            skipSpaces()
            guard peek() == "=" else { throw err("expected '=' in inline table") }
            i += 1
            skipSpaces()
            let value = try parseValue()
            try t.setKey(path, value)
            skipSpaces()
            guard let c = peek() else { throw err("unterminated inline table") }
            if c == "," {
                i += 1
                skipSpaces()
                if peek() == "}" { throw err("trailing comma in inline table") }
            } else if c == "}" {
                i += 1
                return t.toTyped()
            } else if c == "\n" || c == "\r" {
                throw err("newline inside inline table")
            } else {
                throw err("expected ',' or '}' in inline table")
            }
        }
    }

    /// Parse a (possibly dotted, possibly quoted) key path inside an inline
    /// table. Reuses the lossless dotted-key lexer for a single segment run.
    mutating func parseKeyPath() throws -> [String] {
        var segs: [String] = []
        while true {
            skipSpaces()
            guard let c = peek() else { throw err("expected key") }
            if c == "\"" || c == "'" {
                let (next, closed, multiline) = Toml.lexScanQuoted(a, i)
                guard closed, !multiline else { throw err("invalid quoted key") }
                let body = Array(a[(i + 1)..<(next - 1)])
                i = next
                if c == "\"" { segs.append(try decodeBasic(body, multiline: false)) }
                else         { segs.append(try decodeLiteral(body, multiline: false)) }
            } else {
                var bare = String.UnicodeScalarView()
                while let d = peek(), isBareKeyChar(d) { bare.append(d); i += 1 }
                let s = String(bare)
                guard !s.isEmpty else { throw err("invalid key character") }
                segs.append(s)
            }
            skipSpaces()
            if peek() == "." { i += 1; continue }
            break
        }
        return segs
    }

    // MARK: numbers (integer / float / specials)

    mutating func parseNumber() throws -> Toml.TypedValue {
        // Lex the maximal bare token (alnum + _ . + -).
        let start = i
        while let c = peek(), isNumberChar(c) { i += 1 }
        let tok = String(String.UnicodeScalarView(a[start..<i]))
        guard !tok.isEmpty else { throw err("invalid value") }

        // Special floats (lowercase only, optional sign).
        switch tok {
        case "inf", "+inf": return .float(.infinity)
        case "-inf":        return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }

        // Radix-prefixed integers (no sign allowed).
        if tok.hasPrefix("0x") { return .integer(try radixInt(tok, prefix: "0x", radix: 16)) }
        if tok.hasPrefix("0o") { return .integer(try radixInt(tok, prefix: "0o", radix: 8)) }
        if tok.hasPrefix("0b") { return .integer(try radixInt(tok, prefix: "0b", radix: 2)) }

        // Float (has '.', 'e'/'E') vs decimal integer.
        if tok.contains(".") || tok.contains("e") || tok.contains("E") {
            return .float(try decimalFloat(tok))
        }
        return .integer(try decimalInt(tok))
    }

    /// Strict decimal integer: optional sign, no leading zeros (except `0`),
    /// underscores only between digits, 64-bit range.
    func decimalInt(_ tok: String) throws -> Int64 {
        var s = Substring(tok)
        var neg = false
        if let f = s.first, f == "+" || f == "-" { neg = (f == "-"); s = s.dropFirst() }
        let digits = try ungroup(s, allowed: { $0.isASCIIDigit })
        try checkNoLeadingZero(digits)
        guard let mag = UInt64(digits) else { throw err("integer out of range '\(tok)'") }
        return try signedFrom(mag, neg: neg, tok: tok)
    }

    func radixInt(_ tok: String, prefix: String, radix: Int) throws -> Int64 {
        let body = Substring(tok.dropFirst(prefix.count))
        guard !body.isEmpty else { throw err("empty integer '\(tok)'") }
        let ok: (Character) -> Bool = {
            switch radix {
            case 16: return $0.isHexDigit
            case 8:  return ("0"..."7").contains($0)
            default: return $0 == "0" || $0 == "1"
            }
        }
        let digits = try ungroup(body, allowed: ok)
        // Radix integers are unsigned magnitudes and carry no sign, so the
        // representable range is 0 ... Int64.max (2^63 and above overflow).
        guard let mag = UInt64(digits, radix: radix), mag <= UInt64(Int64.max) else {
            throw err("integer out of range '\(tok)'")
        }
        return Int64(mag)
    }

    /// Strict decimal float: optional sign, integer part (no leading zeros),
    /// and at least one of a fractional part (`.` digits) or an exponent
    /// (`e`/`E` [±] digits). Underscores only between digits.
    func decimalFloat(_ tok: String) throws -> Double {
        var sign = ""
        var s = Substring(tok)
        if let f = s.first, f == "+" || f == "-" {
            if f == "-" { sign = "-" }
            s = s.dropFirst()
        }

        var mantissa = s
        var expPart: Substring? = nil
        if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = s[s.startIndex..<eIdx]
            expPart = s[s.index(after: eIdx)...]
        }

        var intPart = mantissa
        var fracPart: Substring? = nil
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = mantissa[mantissa.startIndex..<dot]
            fracPart = mantissa[mantissa.index(after: dot)...]
        }

        let intDigits = try ungroup(intPart, allowed: { $0.isASCIIDigit })
        try checkNoLeadingZero(intDigits)
        var normalized = sign + intDigits
        if let f = fracPart {
            let fd = try ungroup(f, allowed: { $0.isASCIIDigit })
            guard !fd.isEmpty else { throw err("float fraction needs a digit '\(tok)'") }
            normalized += "." + fd
        }
        if let e = expPart {
            var es = e
            var esign = ""
            if let f = es.first, f == "+" || f == "-" { esign = String(f); es = es.dropFirst() }
            let ed = try ungroup(es, allowed: { $0.isASCIIDigit })
            guard !ed.isEmpty else { throw err("float exponent needs a digit '\(tok)'") }
            normalized += "e" + esign + ed       // exponent MAY have leading zeros
        }
        guard let d = Double(normalized) else { throw err("invalid float '\(tok)'") }
        return d
    }

    /// Remove `_` group separators, requiring each to sit BETWEEN two allowed
    /// digits, and requiring every remaining char to be `allowed`.
    func ungroup(_ s: Substring, allowed: (Character) -> Bool) throws -> String {
        guard !s.isEmpty else { throw err("empty number") }
        var out = ""
        let chars = Array(s)
        for (idx, ch) in chars.enumerated() {
            if ch == "_" {
                let prevOK = idx > 0 && allowed(chars[idx - 1])
                let nextOK = idx + 1 < chars.count && allowed(chars[idx + 1])
                guard prevOK && nextOK else { throw err("misplaced '_' in number") }
                continue
            }
            guard allowed(ch) else { throw err("invalid digit '\(ch)' in number") }
            out.append(ch)
        }
        return out
    }

    private func checkNoLeadingZero(_ digits: String) throws {
        guard !digits.isEmpty else { throw err("empty integer") }
        if digits.count > 1 && digits.first == "0" { throw err("leading zeros are not allowed") }
    }

    private func signedFrom(_ mag: UInt64, neg: Bool, tok: String) throws -> Int64 {
        if neg {
            if mag <= UInt64(Int64.max) { return -Int64(mag) }
            if mag == UInt64(Int64.max) + 1 { return Int64.min }
            throw err("integer out of range '\(tok)'")
        } else {
            guard mag <= UInt64(Int64.max) else { throw err("integer out of range '\(tok)'") }
            return Int64(mag)
        }
    }

    // MARK: datetimes

    func looksLikeDate() -> Bool {
        guard i + 9 < a.count else { return false }   // need 10 scalars: dddd-dd-dd
        func d(_ o: Int) -> Bool { isDigitScalar(a[i + o]) }
        return d(0) && d(1) && d(2) && d(3) && a[i+4] == "-"
            && d(5) && d(6) && a[i+7] == "-" && d(8) && d(9)
    }
    func looksLikeTime() -> Bool {
        guard i + 2 < a.count else { return false }
        return isDigitScalar(a[i]) && isDigitScalar(a[i+1]) && a[i+2] == ":"
    }

    mutating func parseDateTime() throws -> Toml.TypedValue {
        if looksLikeDate() {
            let date = try readDate()
            // Optional time, delimited by T/t or a single space.
            var delim: Bool = false
            if let c = peek(), c == "T" || c == "t" { i += 1; delim = true }
            else if peek() == " ", let n = peek(1), isDigitScalar(n) { i += 1; delim = true }
            if delim {
                let (time, offset) = try readTimeAndOffset()
                let dt = Toml.DateTime(date: date, time: time, offset: offset)
                return offset == nil ? .localDateTime(dt) : .offsetDateTime(dt)
            }
            return .localDate(date)
        } else {
            let (time, offset) = try readTimeAndOffset()
            guard offset == nil else { throw err("a bare time cannot carry an offset") }
            return .localTime(time)
        }
    }

    private mutating func readDate() throws -> Toml.LocalDate {
        guard let y = readDigits(4), peekConsume("-"), let m = readDigits(2),
              peekConsume("-"), let d = readDigits(2) else { throw err("malformed date") }
        try validateDate(y, m, d)
        return Toml.LocalDate(year: y, month: m, day: d)
    }

    private mutating func readTimeAndOffset() throws -> (Toml.LocalTime, Toml.Offset?) {
        guard let h = readDigits(2), peekConsume(":"), let mi = readDigits(2), peekConsume(":"),
              let se = readDigits(2) else { throw err("malformed time") }
        var frac = ""
        if peek() == "." {
            i += 1
            var f = String.UnicodeScalarView()
            while let c = peek(), isDigitScalar(c) { f.append(c); i += 1 }
            frac = String(f)
            guard !frac.isEmpty else { throw err("empty fractional seconds") }
        }
        try validateTime(h, mi, se)
        let time = Toml.LocalTime(hour: h, minute: mi, second: se, fraction: frac)

        // Offset: Z / z / ±HH:MM
        if let c = peek() {
            if c == "Z" || c == "z" { i += 1; return (time, .utc) }
            if c == "+" || c == "-" {
                i += 1
                guard let oh = readDigits(2), peekConsume(":"), let om = readDigits(2) else {
                    throw err("malformed offset")
                }
                guard oh <= 23, om <= 59 else { throw err("offset out of range") }
                return (time, .hours(sign: c == "-" ? -1 : 1, hour: oh, minute: om))
            }
        }
        return (time, nil)
    }

    private mutating func readDigits(_ n: Int) -> Int? {
        guard i + n <= a.count else { return nil }
        var v = 0
        for k in 0..<n {
            guard isDigitScalar(a[i + k]) else { return nil }
            v = v * 10 + Int(a[i + k].value - 0x30)
        }
        i += n
        return v
    }
    private mutating func peekConsume(_ s: Unicode.Scalar) -> Bool {
        if peek() == s { i += 1; return true }
        return false
    }

    private func validateDate(_ y: Int, _ m: Int, _ d: Int) throws {
        guard (1...12).contains(m) else { throw err("month out of range") }
        let leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
        let dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        guard (1...dim).contains(d) else { throw err("day out of range") }
    }
    private func validateTime(_ h: Int, _ mi: Int, _ s: Int) throws {
        guard h <= 23 else { throw err("hour out of range") }
        guard mi <= 59 else { throw err("minute out of range") }
        guard s <= 60 else { throw err("second out of range") }   // 60 = leap second
    }

    // MARK: scalar predicates

    func isBareKeyChar(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
            || s == "_" || s == "-"
    }
    func isNumberChar(_ s: Unicode.Scalar) -> Bool {
        (s >= "0" && s <= "9") || (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
            || s == "_" || s == "." || s == "+" || s == "-"
    }
    func isDigitScalar(_ s: Unicode.Scalar) -> Bool { s >= "0" && s <= "9" }

    func hexVal(_ s: Unicode.Scalar) -> Int? {
        switch s {
        case "0"..."9": return Int(s.value - 0x30)
        case "a"..."f": return Int(s.value - 0x61 + 10)
        case "A"..."F": return Int(s.value - 0x41 + 10)
        default: return nil
        }
    }
}

extension Toml {
    /// Decode one key segment's quoting for the lossless DOM's key/path
    /// identity: a basic-quoted key (`"…"`) has its escapes processed (so
    /// `"À"` and `À` are the SAME key), a literal-quoted key (`'…'`) is
    /// verbatim, a bare key is returned unchanged. Best-effort — an invalid
    /// escape falls back to the raw interior; strict key-escape rejection is the
    /// decoder's job (step 7).
    static func decodeKeySegment(_ raw: String) -> String {
        let a = Array(raw.unicodeScalars)
        guard a.count >= 2 else { return raw }
        let f = a[0], l = a[a.count - 1]
        if f == "\"" && l == "\"" {
            let body = Array(a[1..<(a.count - 1)])
            let p = StrictParser([], line: 0)
            if let s = try? p.decodeBasic(body, multiline: false) { return s }
            return String(String.UnicodeScalarView(body))
        }
        if f == "'" && l == "'" {
            return String(String.UnicodeScalarView(a[1..<(a.count - 1)]))
        }
        return raw
    }
}

private extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
