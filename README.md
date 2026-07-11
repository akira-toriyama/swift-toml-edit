# swift-toml-edit

Format-preserving TOML for Swift — the [`toml_edit`](https://docs.rs/toml_edit) /
[`tomlkit`](https://github.com/sdispater/tomlkit) equivalent the ecosystem was
missing. Parse a TOML document into a **lossless DOM**, edit it, and serialize
it back **byte-for-byte identical** except where you changed it: comments,
ordering, blank lines, indentation, quoting style and number spelling are all
preserved.

- **Zero dependencies** — pure Swift + Foundation. Builds on macOS and Linux.
- **`Sendable`** value-type DOM (`Toml.Annotated`); editing is functional
  (returns a new document, no in-place mutation).
- A **lossy read projection** (`Toml.parse` / `Toml.parseFlat` / `Toml.Value` /
  `Toml.Document`) for callers that just want the values.

> Module name is `Toml` (bare, idiomatic). `import Toml`.

## Status

The 1.0 bar — **full TOML 1.0 round-trip** — is **met**: the library passes the
entire official [`toml-test`](https://github.com/toml-lang/toml-test) 1.0.0 suite
in **both directions** (decoder and encoder), and a byte-identity corpus +
generative fuzzer guard the round-trip invariant on top. The public API follows
semantic versioning; the current major is **v2** (v2.0 gave array-of-tables rows
a typed `SourceSpan`; v2.1 added the per-element value edit ops and `Toml.encode`).

## Usage

```swift
import Toml

// Parse into the lossless DOM, edit, and write back — unchanged bytes stay byte-
// for-byte identical; only the edited block re-renders.
let doc = try Toml.Annotated(parsing: source)
let reordered = doc.reorderingArrayOfTables(at: ["server"], [1, 0])
// v2.1: surgical value writes — only the value token is replaced; the
// entry's indent / spacing / same-line comment stay verbatim.
let named = reordered.settingValue(.string("prod"),
    atArrayOfTablesElement: ["server"], ordinal: 0, forKey: "name")
let out = named.render()              // comments / spacing / quoting preserved

// Just want the values? Use the lossy projection.
let flat = Toml.parseFlat(source)
let port = flat.tables["server"]?["port"]?.asInt

// Need fully-typed values (the four datetime kinds, exact integers, …)?
let typed = try doc.typedTree()       // a Toml.TypedValue tree
```

## Conformance

Verified against the official `toml-test` v2.2.0 runner, pinned to TOML 1.0.0
(`scripts/conformance.sh`, and gated in CI):

| direction | result |
|-----------|--------|
| decoder — valid   | 205 / 205 |
| decoder — invalid | 474 / 474 rejected |
| encoder           | 205 / 205 |

## Why

It is the shared TOML library for the [atelier](https://github.com/akira-toriyama)
swift app family, whose `config.toml` files are hand-curated — the comments and
layout are the documentation. A parser that throws them away on write is not an
option. See `CLAUDE.md` for the design and invariants.

## Install

```swift
.package(url: "https://github.com/akira-toriyama/swift-toml-edit", from: "2.1.0")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "Toml", package: "swift-toml-edit"),
])
```

## License

MIT — see [LICENSE](LICENSE).
