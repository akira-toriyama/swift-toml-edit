// Source spans for the lossy nested `parse` projection.
//
// An array-of-tables row carries its `[[header]]` location as a TYPED
// `SourceSpan` on a dedicated `Row` value, never as a synthetic dict key
// (`__line__`): a synthetic key leaks into every field iteration, can be
// shadowed by a user key of the same name, and must be re-threaded by hand
// when a consumer synthesizes a row. A `Row` rides along on Swift value-copy
// when a consumer clones a row, which fits the row-clone desugaring the
// family's config layers use.
//
// Only the nested strict parse constructs `Row`s. `parseFlat` keeps its rows
// as plain `[[String: Value]]` — its flat consumers don't attribute warnings.
//
// Row spans locate the `[[header]]`; ENTRY-level key/value locations (the
// column-precise `(config.toml:N:C)` input) live in `parseWithSpans`'s side
// index — see ParseWithSpans.swift.

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

    /// One element of an array-of-tables: the row's fields plus the
    /// `SourceSpan` of the `[[header]]` that opened it. The subscript forwards
    /// to `fields` so a consumer reads `row["input"]` exactly like the bare
    /// dict it replaced.
    struct Row: Sendable, Equatable {
        public var fields: [String: Value]
        /// `nil` for a hand-constructed row.
        public var span: SourceSpan?

        public init(fields: [String: Value] = [:], span: SourceSpan? = nil) {
            self.fields = fields
            self.span = span
        }

        public subscript(_ key: String) -> Value? {
            get { fields[key] }
            set { fields[key] = newValue }
        }
    }
}
