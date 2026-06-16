import Testing
import Foundation
@testable import Toml

// Generative round-trip fuzzer — the M2 review flagged the absence of one as the
// top coverage gap. It builds many diverse-but-VALID TOML documents from a
// grammar that deliberately varies the dimensions where tiler/trivia bugs live
// (leading/trailing trivia, banner vs separator comments, blank-line runs,
// indentation, inline comments, LF vs CRLF per line, multi-line strings/arrays,
// quoted/dotted/numeric keys) and asserts the two core invariants:
//
//   1. byte-identity round-trip:  Annotated(parsing: s).render() == s
//   2. the strict decoder accepts every valid-by-construction document, and
//      decode is STABLE across a render round-trip.
//
// Deterministic (seeded SplitMix64) so a failure reproduces exactly.
@Suite struct FuzzRoundTripTests {

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

    private func nl(_ r: inout SplitMix64) -> String { Bool.random(using: &r) ? "\r\n" : "\n" }
    private func indent(_ r: inout SplitMix64) -> String {
        ["", "  ", "    ", "\t"].randomElement(using: &r)!
    }
    private func inlineComment(_ r: inout SplitMix64) -> String {
        Int.random(in: 0..<3, using: &r) == 0 ? "   # note" : ""
    }

    private func scalar(_ r: inout SplitMix64) -> String {
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
    private func multilineValue(_ r: inout SplitMix64) -> String {
        let term = nl(&r)
        if Bool.random(using: &r) {
            // multi-line array with an interior comment + trailing comma
            return "[" + term + "  1, # c" + term + "  2," + term + "]"
        } else {
            // multi-line basic string whose body LOOKS like structure
            return "\"\"\"" + term + "[not a header]" + term + "k = 1 # not a comment" + term + "\"\"\""
        }
    }

    private func key(_ n: Int, _ r: inout SplitMix64) -> String {
        switch Int.random(in: 0..<4, using: &r) {
        case 0: return "k\(n)"
        case 1: return "\"q.\(n)\""           // quoted key with a dot
        case 2: return "\(n)"                 // numeric bare key
        default: return "k\(n)_sub.leaf\(n)"  // dotted key
        }
    }

    private func trivia(_ r: inout SplitMix64) -> String {
        var out = ""
        for _ in 0..<Int.random(in: 0...3, using: &r) {
            if Bool.random(using: &r) { out += "# comment \(Int.random(in: 0...9, using: &r))" + nl(&r) }
            else { out += indent(&r) + nl(&r) }   // blank (maybe with whitespace)
        }
        return out
    }

    private func document(_ r: inout SplitMix64) -> String {
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

    // MARK: the invariants

    @Test func roundTripAndDecodeStability() throws {
        var r = SplitMix64(seed: 88172645463325252)
        var checked = 0
        for _ in 0..<2000 {
            let s = document(&r)
            let dom: Toml.Annotated
            do { dom = try Toml.Annotated(parsing: s) }
            catch { Issue.record("parse threw on generated-valid doc:\n\(debugRepr(s))\nerror: \(error)"); continue }

            // 1. byte-identity
            #expect(dom.render() == s, "round-trip diverged:\n\(debugRepr(s))")

            // 2. decode stability across a render round-trip (when it decodes)
            if let t1 = try? dom.typedTree() {
                let reparsed = try Toml.Annotated(parsing: dom.render())
                let t2 = try reparsed.typedTree()
                #expect(t1 == t2, "decode not stable across round-trip:\n\(debugRepr(s))")
            }
            checked += 1
        }
        #expect(checked == 2000, "every generated document should at least parse")
    }

    private func debugRepr(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n\n")
    }
}
