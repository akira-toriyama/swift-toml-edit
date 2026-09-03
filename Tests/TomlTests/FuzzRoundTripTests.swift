import Testing
import Foundation
@testable import Toml

// Generative round-trip fuzzer over the shared TomlFuzzGen grammar
// (FuzzGen.swift), asserting the two core invariants the hand-written
// fixtures cannot cover exhaustively:
//
//   1. byte-identity round-trip:  Annotated(parsing: s).render() == s
//   2. the strict decoder accepts every valid-by-construction document, and
//      decode is STABLE across a render round-trip.
@Suite struct FuzzRoundTripTests {

    @Test func roundTripAndDecodeStability() throws {
        var r = TomlFuzzGen.SplitMix64(seed: 88172645463325252)
        var checked = 0
        for _ in 0..<2000 {
            let s = TomlFuzzGen.document(&r)
            let dom: Toml.Annotated
            do { dom = try Toml.Annotated(parsing: s) }
            catch { Issue.record("parse threw on generated-valid doc:\n\(debugRepr(s))\nerror: \(error)"); continue }

            #expect(dom.render() == s, "round-trip diverged:\n\(debugRepr(s))")

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
