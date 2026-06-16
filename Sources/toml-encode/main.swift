// toml-test encoder binary.
//
// Contract (toml-lang/toml-test): read toml-test tagged JSON from stdin and
// write a TOML encoding to stdout (exit 0), or exit non-zero if the input can't
// be represented. The runner grades by ROUND-TRIP — it re-decodes our TOML with
// a blessed reference decoder and compares semantically to the input — so the
// output need only be valid TOML that decodes back to the same data.

import Foundation
import Toml

let data = FileHandle.standardInput.readDataToEndOfFile()

do {
    let value = try Toml.decodeTaggedJSON(data)
    let toml = try value.serializeDocument()
    FileHandle.standardOutput.write(Data(toml.utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("toml-encode: \(error)\n".utf8))
    exit(1)
}
