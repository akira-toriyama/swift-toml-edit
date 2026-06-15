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

Pre-1.0 and under active development. The 1.0 bar is **full TOML 1.0
round-trip**, verified by the official
[`toml-test`](https://github.com/toml-lang/toml-test) conformance suite plus an
in-repo byte-identity corpus. Until then the API may move.

## Why

It is the shared TOML library for the [atelier](https://github.com/akira-toriyama)
swift app family, whose `config.toml` files are hand-curated — the comments and
layout are the documentation. A parser that throws them away on write is not an
option. See `CLAUDE.md` for the design and invariants.

## Install

```swift
.package(url: "https://github.com/akira-toriyama/swift-toml-edit", from: "0.1.0")
```

```swift
.target(name: "YourTarget", dependencies: [
    .product(name: "Toml", package: "swift-toml-edit"),
])
```

## License

MIT — see [LICENSE](LICENSE).
