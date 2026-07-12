import Foundation

// Shared deterministic TOML document generator — extracted from
// FuzzRoundTripTests so the lossy-derivation equivalence suite
// (ParseWithSpansTests) can fuzz the SAME grammar. It builds many
// diverse-but-VALID TOML documents, deliberately varying the dimensions where
// tiler/trivia bugs live (leading/trailing trivia, banner vs separator
// comments, blank-line runs, indentation, inline comments, LF vs CRLF per
// line, multi-line strings/arrays, quoted/dotted/numeric keys).
//
// Deterministic (seeded SplitMix64) so a failure reproduces exactly. The
// extraction is call-order-preserving: FuzzRoundTripTests' seed produces the
// same document sequence it did before the move.
enum TomlFuzzGen {

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: generators (all produce VALID, parseable TOML)

    private static func nl(_ r: inout SplitMix64) -> String { Bool.random(using: &r) ? "\r\n" : "\n" }
    private static func indent(_ r: inout SplitMix64) -> String {
        ["", "  ", "    ", "\t"].randomElement(using: &r)!
    }
    private static func inlineComment(_ r: inout SplitMix64) -> String {
        Int.random(in: 0..<3, using: &r) == 0 ? "   # note" : ""
    }

    private static func scalar(_ r: inout SplitMix64) -> String {
        switch Int.random(in: 0..<9, using: &r) {
        case 0: return String(Int.random(in: -9999...9999, using: &r))
        case 1: return "0x" + String(UInt.random(in: 0...0xFFFFFF, using: &r), radix: 16)
        case 2: return "\(Int.random(in: 0...999, using: &r)).\(Int.random(in: 0...999, using: &r))"
        case 3: return Bool.random(using: &r) ? "true" : "false"
        case 4: return "\"safe text \(Int.random(in: 0...99, using: &r))\""
        case 5: return "'literal \(Int.random(in: 0...99, using: &r))'"
        case 6: return "1979-05-27T07:32:00Z"
        case 7: // single-line array
            let n = Int.random(in: 0...3, using: &r)
            return "[" + (0..<n).map { _ in String(Int.random(in: 0...9, using: &r)) }.joined(separator: ", ") + "]"
        default: return "\"#has = [tricky] chars\""   // exercises comment/bracket scanners
        }
    }

    /// A value that spans physical lines (multi-line array or multi-line string).
    private static func multilineValue(_ r: inout SplitMix64) -> String {
        let term = nl(&r)
        if Bool.random(using: &r) {
            // multi-line array with an interior comment + trailing comma
            return "[" + term + "  1, # c" + term + "  2," + term + "]"
        } else {
            // multi-line basic string whose body LOOKS like structure
            return "\"\"\"" + term + "[not a header]" + term + "k = 1 # not a comment" + term + "\"\"\""
        }
    }

    private static func key(_ n: Int, _ r: inout SplitMix64) -> String {
        switch Int.random(in: 0..<4, using: &r) {
        case 0: return "k\(n)"
        case 1: return "\"q.\(n)\""           // quoted key with a dot
        case 2: return "\(n)"                 // numeric bare key
        default: return "k\(n)_sub.leaf\(n)"  // dotted key
        }
    }

    private static func trivia(_ r: inout SplitMix64) -> String {
        var out = ""
        for _ in 0..<Int.random(in: 0...3, using: &r) {
            if Bool.random(using: &r) { out += "# comment \(Int.random(in: 0...9, using: &r))" + nl(&r) }
            else { out += indent(&r) + nl(&r) }   // blank (maybe with whitespace)
        }
        return out
    }

    static func document(_ r: inout SplitMix64) -> String {
        var s = ""
        var keyN = 0
        // doc-level leading
        if Bool.random(using: &r) { s += "#:schema ./x.json" + nl(&r) }
        s += trivia(&r)
        // root entries
        for _ in 0..<Int.random(in: 0...2, using: &r) {
            s += trivia(&r) + indent(&r) + key(keyN, &r) + " = " + scalar(&r) + inlineComment(&r) + nl(&r)
            keyN += 1
        }
        // sections
        for sec in 0..<Int.random(in: 0...4, using: &r) {
            s += trivia(&r)
            let aot = Bool.random(using: &r)
            s += aot ? "[[a\(sec)]]" + nl(&r) : "[s\(sec)]" + nl(&r)
            for _ in 0..<Int.random(in: 0...3, using: &r) {
                s += indent(&r) + key(keyN, &r) + " = "
                s += Int.random(in: 0..<5, using: &r) == 0 ? multilineValue(&r) : scalar(&r)
                s += inlineComment(&r) + nl(&r)
                keyN += 1
            }
        }
        s += trivia(&r)
        // sometimes drop the very last newline
        if Bool.random(using: &r), s.hasSuffix("\n") {
            s.removeLast()
            if s.hasSuffix("\r") { s.removeLast() }
        }
        return s
    }
}
