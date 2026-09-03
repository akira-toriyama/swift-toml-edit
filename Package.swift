// swift-tools-version:6.0
// swift-toml-edit — format-preserving TOML for Swift (the toml_edit / tomlkit
// equivalent), the atelier family's ONE TOML implementation: a lossless
// `Toml.Annotated` DOM plus the lossy `parse` / `parseFlat` projection the
// five consumers read config through (design brief: atelier
// docs/swift-toml-edit.md).
//
// ONE module, `Toml` — a bare name is idiomatic (swift-algorithms ships
// `Algorithms`), and the five consumers' `import Toml` depends on it.
//
// ZERO external dependencies (the family rule) and Foundation-only, so the
// package builds and tests on Linux via swift-corelibs-foundation. Linux is
// load-bearing, not incidental: the official `toml-test` conformance job runs
// there. The library must therefore stay `canImport(AppKit)`-free. The
// `platforms:` floor only constrains Apple platforms; macOS 13 matches the
// consumers' floor.

import PackageDescription

let package = Package(
    name: "swift-toml-edit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "Toml", targets: ["Toml"]),
        // Driven by the official toml-test harness (scripts/conformance.sh +
        // ci.yml); not products for consumers.
        .executable(name: "toml-decode", targets: ["toml-decode"]),
        .executable(name: "toml-encode", targets: ["toml-encode"]),
    ],
    targets: [
        .target(name: "Toml"),
        .executableTarget(name: "toml-decode", dependencies: ["Toml"]),
        .executableTarget(name: "toml-encode", dependencies: ["Toml"]),

        // `Fixtures/` holds the family's real configs for the round-trip
        // byte-identity goldens; the resource copy puts them in Bundle.module.
        .testTarget(
            name: "TomlTests",
            dependencies: ["Toml"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
