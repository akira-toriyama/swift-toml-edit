// Source spans for the lossy nested `parse` projection.
//
// The lossy `parse` (nested, strict — the chord path) used to attribute a
// warning to its source line via a synthetic `__line__` dict key seeded into
// every array-of-tables row. That key was a leaky abstraction: every consumer
// iterating a row's fields had to skip it, a user key literally named
// `__line__` could shadow it, and synthesized rows had to re-thread it by hand.
//
// It is replaced by a TYPED location carried on a dedicated `Row` value: each
// element of `Value.arrayOfTables` is now a `Row` (its `fields` dict + the
// `SourceSpan` of the `[[header]]` that opened it), not a bare
// `[String: Value]`. The span can't collide with a user key, never appears in
// a field iteration, and rides along on Swift value-copy when a consumer
// clones a row to synthesize a new one — so it fits the row-clone desugaring
// the family's config layers already use.
//
// Only the nested strict parses (`parse`, and its DOM-derived twin
// `parseWithSpans`) construct `Row`s. `parseFlat` keeps its rows as plain
// `[[String: Value]]` (its flat consumers don't need attribution).
//
// Row spans locate the `[[header]]`; ENTRY-level key/value locations (the
// column-precise `(config.toml:N:C)` input) live in `parseWithSpans`'s
// side index — see ParseWithSpans.swift.

import Foundation

public extension Toml {

    /// A 1-based source location captured by the nested strict `parse`.
    /// `line` is the 1-based physical line of the construct; `column` is the
    /// 1-based column of its first non-whitespace character on that line, or
    /// `nil` when not computed (e.g. a hand-constructed `Row`).
    struct SourceSpan: Sendable, Equatable, Hashable {
        public var line: Int
        public var column: Int?
        public init(line: Int, column: Int? = nil) {
            self.line = line
            self.column = column
        }
    }

    /// One element of an array-of-tables: the row's `key = value` fields plus
    /// the `SourceSpan` of the `[[header]]` that opened it.
    ///
    /// Constructed only by the nested strict `parse` (`parseFlat` keeps its
    /// rows as plain `[[String: Value]]`). The `subscript` forwards to
    /// `fields`, so a consumer reads `row["input"]` exactly as it read a bare
    /// dict before — the only new surface is `row.span`.
    struct Row: Sendable, Equatable {
        /// The row's `key = value` assignments (dotted keys collapsed to
        /// nested tables, same as the rest of `parse`'s tree).
        public var fields: [String: Value]
        /// The `[[header]]` location, or `nil` for a hand-constructed row.
        public var span: SourceSpan?

        public init(fields: [String: Value] = [:], span: SourceSpan? = nil) {
            self.fields = fields
            self.span = span
        }

        /// Field access sugar: `row["input"]` reads/writes `fields["input"]`.
        public subscript(_ key: String) -> Value? {
            get { fields[key] }
            set { fields[key] = newValue }
        }
    }
}
