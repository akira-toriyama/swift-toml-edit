// toml-test decoder binary.
//
// Contract (toml-lang/toml-test): read a TOML document from stdin to EOF. If it
// is valid, write its tagged-JSON encoding to stdout and exit 0. If it is
// invalid, write nothing to stdout, a diagnostic to stderr, and exit non-zero.
// The runner re-spawns this process once per test, so a plain read→decode→print
// filter is correct.
//
// Decoding path: lossless parse (`Toml.Annotated`) → typed tree (`typedTree`,
// which decodes every leaf with the strict `decodeStrict`) → tagged JSON. Any
// thrown `Toml.ParseError` (malformed structure or value) becomes a non-zero
// exit, which is exactly what the invalid corpus expects.

import Foundation
import Toml

let data = FileHandle.standardInput.readDataToEndOfFile()

// Strict UTF-8: a TOML document MUST be valid UTF-8. `String(decoding:as:)`
// would silently substitute U+FFFD for malformed bytes (accepting the
// invalid/encoding/* corpus), so decode strictly and reject on failure.
guard let source = String(data: data, encoding: .utf8) else {
    FileHandle.standardError.write(Data("toml-decode: input is not valid UTF-8\n".utf8))
    exit(1)
}

do {
    let doc = try Toml.Annotated(parsing: source)
    let tree = try doc.typedTree()
    // Build the whole JSON before printing so a late error never emits partial
    // output to stdout (which the runner would read as a spurious success).
    let json = tree.taggedJSON()
    FileHandle.standardOutput.write(Data(json.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("toml-decode: \(error)\n".utf8))
    exit(1)
}
