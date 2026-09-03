// Toml.Annotated — the lossless, format-preserving DOM. It preserves EVERY
// byte: comments, blank lines, ordering, indentation, quoting style, number
// spelling and the `#:schema` pragma. The invariant, checked in CI, is
// byte-identical round-trip:
//
//     try Toml.Annotated(parsing: s).render() == s        // for any document we parse
//
// Guaranteed the way toml_edit / tomlkit do it: every node stores its exact
// source spelling (`raw`) plus the verbatim trivia attached to it, and
// rendering concatenates those spans. An UNEDITED node always re-emits its
// original bytes; only an edited block re-renders, so neighbours stay
// byte-stable.
//
// Node types are nested under `Annotated` (`Toml.Annotated.Block` / `.Body` /
// `.Entry`) so they do NOT collide with the lossy projection's `Toml.Value` /
// `Toml.Document`.
//
// Trivia attribution (the wand#129 rule): a comment banner attaches to the
// header (or key) block that immediately FOLLOWS it and travels with that
// block on reorder / delete; the blank-line separator before a banner stays
// with the PRECEDING block. The bytes before the very first content token
// (the `#:schema` pragma + file header) are document-level `leading` and
// never move.
//
// Values are kept as raw spelling. A lenient typed decode is available on
// demand via `Entry.value`; the conformance-grade strict decode + the
// redefinition state machine live in DecodeStrict.swift / TypedTree.swift,
// and editing in AnnotatedEdit.swift — all additive: they read the raw
// spelling without touching this byte-preserving contract.

import Foundation

public extension Toml {

    /// A lossless, round-trippable TOML document. Value type, so every edit
    /// op returns a NEW document.
    struct Annotated: Sendable, Equatable {
        /// Every byte before the first content token (BOM, `#:schema` pragma,
        /// file header comments). Never moves on edit.
        public var leading: String
        /// Top-level key/values before the first `[header]`.
        public var root: Body
        /// The `[table]` / `[[array-element]]` blocks, in document order.
        public var blocks: [Block]

        public init(leading: String = "", root: Body = .init(), blocks: [Block] = []) {
            self.leading = leading
            self.root = root
            self.blocks = blocks
        }
    }
}

public extension Toml.Annotated {

    /// The key/values under one scope (the root, a `[table]`, or a `[[aot]]`
    /// element), in document order, plus the trivia trailing the last entry.
    struct Body: Sendable, Equatable {
        public var entries: [Entry] = []
        /// Trivia after the last entry: the blank-line separator(s) before the
        /// next header (the banner above that header is ITS leading — the
        /// wand#129 split), or everything to EOF for the final body.
        public var trailing: String = ""

        public init(entries: [Entry] = [], trailing: String = "") {
            self.entries = entries
            self.trailing = trailing
        }

        /// First entry whose key matches `key`, or nil. `key` is dotted-key
        /// SOURCE syntax — `a.b` is the path `["a","b"]`, so a key literally
        /// NAMED `a.b` must be quoted (`"a.b"`) or looked up via
        /// `entry(forKeyParts:)`. Quoting style of bare segments does not
        /// matter (`"x"` and `x` both resolve to `["x"]`).
        public func entry(forKey key: String) -> Entry? {
            entry(forKeyParts: Toml.lexDottedPath(key))
        }

        /// First entry whose parsed key parts equal `parts`, or nil — for a
        /// key whose name contains a literal dot, or to reuse an `Entry.key`
        /// without re-quoting it.
        public func entry(forKeyParts parts: [String]) -> Entry? {
            entries.first { $0.key == parts }
        }
    }

    /// One `key = value` assignment. A value that spans physical lines is
    /// covered whole by `raw`.
    struct Entry: Sendable, Equatable {
        /// Comments / blank lines immediately before this entry — moves and
        /// deletes with it.
        public var leading: String
        /// The exact source of the assignment, including any same-line
        /// comment and the terminator. Round-trip emits this verbatim.
        public var raw: String
        /// The parsed dotted key, escape-decoded (`"q.k" = …` → `["q.k"]`,
        /// `a.b = …` → `["a","b"]`).
        public var key: [String]
        /// The value's source spelling, comment-stripped and trimmed. Decode
        /// it with `value`.
        public var valueText: String

        public init(leading: String, raw: String, key: [String], valueText: String) {
            self.leading = leading
            self.raw = raw
            self.key = key
            self.valueText = valueText
        }

        /// The value decoded into the lossy `Toml.Value`, or nil if its
        /// spelling is outside the lossy scalar grammar. Computed on demand:
        /// the DOM stores only the spelling, which is the source of truth for
        /// round-trip.
        public var value: Toml.Value? { Toml.decodeScalar(valueText) }
    }

    /// A `[table]` block or one `[[array-of-tables]]` element block, with the
    /// key/values that follow it.
    struct Block: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case table          // `[header]`
            case arrayElement   // `[[header]]`
        }
        /// The comment banner before the header line — moves and deletes with
        /// the block (the wand#129 rule).
        public var leading: String
        public var kind: Kind
        /// The exact header line, including any same-line comment and the
        /// terminator.
        public var headerRaw: String
        /// The parsed dotted header path, escape-decoded
        /// (`[behavior."com.apple.x"]` → `["behavior","com.apple.x"]`).
        public var path: [String]
        public var body: Body

        public init(leading: String, kind: Kind, headerRaw: String,
                    path: [String], body: Body) {
            self.leading = leading
            self.kind = kind
            self.headerRaw = headerRaw
            self.path = path
            self.body = body
        }
    }
}

// MARK: - Render (serialize)

public extension Toml.Annotated {
    /// Byte-identical to the parsed source for an unedited document; an
    /// edited block re-renders while its neighbours keep their verbatim bytes.
    func render() -> String {
        var out = leading
        out += root.render()
        for block in blocks { out += block.render() }
        return out
    }
}

extension Toml.Annotated.Body {
    func render() -> String {
        var out = ""
        for entry in entries {
            out += entry.leading
            out += entry.raw
        }
        out += trailing
        return out
    }
}

extension Toml.Annotated.Block {
    func render() -> String {
        leading + headerRaw + body.render()
    }
}
