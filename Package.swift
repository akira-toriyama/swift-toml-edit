// swift-tools-version:6.0
// swift-toml-edit — format-preserving TOML for Swift (the toml_edit / tomlkit
// equivalent). The atelier family's ONE TOML implementation: a lossless,
// round-trippable `Toml.Annotated` DOM that preserves comments, ordering,
// blank lines, indentation and the `#:schema` pragma, PLUS a lossy
// `parse` / `parseFlat` projection that is API-compatible with sill's `Toml`
// module (Sill-1 of the atelier refactor — see atelier docs/swift-toml-edit.md).
//
// ONE module, `Toml` — the bare name is idiomatic (swift-algorithms ships
// `Algorithms`; swift-collections ships `OrderedCollections`) and is kept so
// the five consumers' `import Toml` survives the swap untouched. The lossless
// DOM is `Toml.Annotated` (with its node types nested under it); the lossy
// read shapes are `Toml.Value` / `Toml.Document` (the same names sill exposes).
//
// ZERO external dependencies — pure Swift + Foundation only (the family's
// zero-dep rule). Foundation is the only import and ships on Linux via
// swift-corelibs-foundation, so this package builds and tests on macOS AND
// Linux. The `platforms:` floor only constrains Apple platforms (matching
// sill's macOS 13 so consumers see no regression on swap); Linux is a
// first-class build/test target — load-bearing here, because the official
// `toml-test` conformance harness runs cheaply on Ubuntu. The library code
// must therefore stay `canImport(AppKit)`-free (trivial — TOML editing is
// pure string work).

import PackageDescription

let package = Package(
    name: "swift-toml-edit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "Toml", targets: ["Toml"]),
        // The official toml-test conformance harness drives this: it pipes a
        // TOML document on stdin and expects tagged JSON on stdout (or a
        // non-zero exit for invalid input). See scripts/conformance.sh + CI.
        .executable(name: "toml-decode", targets: ["toml-decode"]),
    ],
    targets: [
        // The library: lossless `Annotated` DOM + functional edit ops
        // (reorderingArrayOfTables / removing) + lossy parse/parseFlat
        // projection + the strict typed decoder (`decodeStrict` / `TypedValue`)
        // backing toml-test conformance. Pure, Sendable, zero-dep.
        .target(name: "Toml"),

        // toml-test decoder binary (stdin TOML → tagged JSON / nonzero exit).
        .executableTarget(name: "toml-decode", dependencies: ["Toml"]),

        // Unit + golden tests. `Fixtures/` holds the family's real configs
        // (perch/wand/chord/facet/halo + still) for round-trip byte-identity
        // goldens; `swift test` copies them into the bundle (Bundle.module).
        .testTarget(
            name: "TomlTests",
            dependencies: ["Toml"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
