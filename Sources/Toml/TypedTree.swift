// Build a fully-typed, nested value tree from the lossless `Annotated` DOM (the
// toml-test decoder path) AND enforce the TOML 1.0 table/key REDEFINITION state
// machine. The lossless tiler is concerned only with structure + byte-faithful
// round-trip; "is this a duplicate table / a header reopening a dotted-key
// table / an array-over-table clash" is a SEMANTIC check that lives here.
//
// Each table node records HOW it was created, which decides what may later
// touch it:
//   • implicit — an intermediate super-table of `[a.b.c]` or a dotted key.
//     OPEN: may gain sub-tables/keys and may be promoted to an explicit table
//     exactly once.
//   • header   — defined by a `[header]`. Open to deeper headers and to keys in
//     its body, but a second identical `[header]` is an error.
//   • dotted   — created by the non-final part of a dotted key. Open to more
//     sibling dotted keys, but CLOSED to a later `[header]` (a dotted-key table
//     cannot be reopened).
//   • inline   — an inline table `{…}`. CLOSED to every later addition.
// Arrays-of-tables are a list of element tables; only the LAST element is open.
//
// The same machine backs inline tables (so `{a.b=1, a.b.c=2}` and `{b=1, b.c=2}`
// are rejected) — `decodeStrict`'s inline-table parser builds a `TreeTable` too.

public extension Toml.Annotated {
    /// Fold this document into a typed `.table` value, decoding each leaf
    /// strictly and enforcing the redefinition rules. Throws on any malformed
    /// value OR illegal redefinition.
    func typedTree() throws -> Toml.TypedValue {
        let tree = Toml.TreeTable(kind: .implicit)
        try tree.addKeys(self.root.entries)
        for block in blocks {
            switch block.kind {
            case .table:
                let t = try tree.defineHeader(block.path)
                try t.addKeys(block.body.entries)
            case .arrayElement:
                let t = try tree.defineArrayElement(block.path)
                try t.addKeys(block.body.entries)
            }
        }
        return tree.toTyped()
    }
}

extension Toml.TreeTable {
    /// Decode + insert a body's `key = value` entries (dotted keys included).
    func addKeys(_ entries: [Toml.Annotated.Entry]) throws {
        for e in entries {
            let value = try Toml.decodeStrict(e.valueText)
            try setKey(e.key, value)
        }
    }
}

extension Toml {
    /// A mutable build node for the typed tree + redefinition machine.
    final class TreeTable {
        enum Kind { case implicit, header, dotted, inline }
        enum Child { case leaf(TypedValue); case table(TreeTable); case aot([TreeTable]) }

        var kind: Kind
        private(set) var order: [String] = []
        private(set) var children: [String: Child] = [:]

        init(kind: Kind) { self.kind = kind }

        private func put(_ k: String, _ c: Child) {
            if children[k] == nil { order.append(k) }
            children[k] = c
        }
        func get(_ k: String) -> Child? { children[k] }

        private func fail(_ m: String) -> Toml.ParseError { Toml.ParseError(line: 0, message: m) }

        // MARK: headers

        /// Define `[path]`, returning the target table to fill with the body.
        func defineHeader(_ path: [String]) throws -> TreeTable {
            let parent = try descend(Array(path.dropLast()))
            guard let last = path.last else { throw fail("empty table header") }
            switch parent.get(last) {
            case nil:
                let t = TreeTable(kind: .header); parent.put(last, .table(t)); return t
            case .table(let t):
                switch t.kind {
                case .implicit: t.kind = .header; return t          // implicit → explicit (once)
                case .header:   throw fail("table '\(last)' defined more than once")
                case .dotted:   throw fail("cannot redefine dotted-key table '\(last)' with a header")
                case .inline:   throw fail("cannot extend inline table '\(last)'")
                }
            case .aot:  throw fail("'\(last)' is already an array of tables")
            case .leaf: throw fail("key '\(last)' is not a table")
            }
        }

        /// Append a new `[[path]]` element, returning it (to fill with the body).
        func defineArrayElement(_ path: [String]) throws -> TreeTable {
            let parent = try descend(Array(path.dropLast()))
            guard let last = path.last else { throw fail("empty array header") }
            let element = TreeTable(kind: .header)
            switch parent.get(last) {
            case nil:            parent.put(last, .aot([element]))
            case .aot(var arr):  arr.append(element); parent.put(last, .aot(arr))
            case .table:         throw fail("'\(last)' is already a table, not an array of tables")
            case .leaf:          throw fail("key '\(last)' is not an array of tables")
            }
            return element
        }

        /// Descend the non-final parts of a HEADER path, creating implicit
        /// super-tables and stepping into the last element of any AoT. A leaf or
        /// an inline table in the way is an error.
        private func descend(_ path: [String]) throws -> TreeTable {
            var cur = self
            for seg in path {
                switch cur.get(seg) {
                case nil:
                    let t = TreeTable(kind: .implicit); cur.put(seg, .table(t)); cur = t
                case .table(let t):
                    if t.kind == .inline { throw fail("cannot extend inline table '\(seg)'") }
                    cur = t
                case .aot(let arr):
                    guard let last = arr.last else { throw fail("empty array of tables '\(seg)'") }
                    cur = last
                case .leaf:
                    throw fail("key '\(seg)' is not a table")
                }
            }
            return cur
        }

        // MARK: keys (plain + dotted), shared by the document and inline tables

        /// Set a (possibly dotted) key to a decoded value, enforcing the
        /// duplicate / closed-table rules. Intermediate tables a dotted key
        /// creates are `dotted` (closed to later headers).
        func setKey(_ path: [String], _ value: TypedValue) throws {
            guard let head = path.first else { return }
            if path.count == 1 {
                if children[head] != nil { throw fail("duplicate key '\(head)'") }
                put(head, .leaf(value))
                return
            }
            let tail = Array(path.dropFirst())
            let sub: TreeTable
            switch get(head) {
            case nil:
                sub = TreeTable(kind: .dotted); put(head, .table(sub))
            case .table(let t):
                // A dotted key may extend a table created by a sibling dotted
                // key (`.dotted`) OR an implicit super-table (`.implicit`, e.g.
                // adding `b.a` under the implicit `b` of a prior `[a.b.c]`). It
                // may NOT reach into a table explicitly defined by a `[header]`
                // (`[a.b.c]` then `[a]` then `b.c.t = …` is invalid) nor into an
                // inline table.
                switch t.kind {
                case .dotted, .implicit: sub = t
                case .inline: throw fail("cannot extend inline table '\(head)'")
                case .header:
                    throw fail("cannot extend table '\(head)' with a dotted key")
                }
            case .aot:  throw fail("cannot extend array of tables '\(head)' with a dotted key")
            case .leaf: throw fail("key '\(head)' is not a table")
            }
            try sub.setKey(tail, value)
        }

        // MARK: lower into the public typed value

        func toTyped() -> TypedValue {
            var out: [(key: String, value: TypedValue)] = []
            for k in order {
                switch children[k]! {
                case .leaf(let v):  out.append((k, v))
                case .table(let t): out.append((k, t.toTyped()))
                case .aot(let arr): out.append((k, .array(arr.map { $0.toTyped() })))
                }
            }
            return .table(out)
        }
    }
}
