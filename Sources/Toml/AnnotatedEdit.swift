// Functional edit ops — the minimal set the family needs: reorder / delete
// array-of-tables elements, delete a std table, and surgical VALUE writes
// (`settingValue` / `upsertingValue` on one `[[path]]` element,
// `settingValue` / `settingArrayValue` under a `[path]` table). Each returns
// a NEW document; the receiver is unchanged. A value write rewrites only the
// value token inside one entry's `raw` (spelled by `Toml.encode`), so
// comments / indent / spacing stay byte-verbatim.
//
// Out of scope on purpose — do not add: from-scratch emit, and APPENDING a
// whole new `[[path]]` element (facet skips + logs that case). Every op is a
// no-op rather than a best effort whenever the result could be invalid TOML:
// a valid document must never render invalid.
//
// Trivia on edit (the wand#129 rule): an element moves / deletes WHOLE — its
// banner comment travels with it so a per-element comment never labels the
// wrong element — while blank-line SEPARATORS stay with the preceding block
// (parsed as its `body.trailing`), so spacing stays uniform. Cosmetic limits,
// matching Rust toml_edit: a banner above the document's FIRST content token
// lives in the never-moving document `leading` and does not travel; with N−1
// separators between N elements, the element that lands LAST may gain or
// lose a trailing blank. Identity permutations are byte-stable.
//
// ASSUMES newline-terminated lines: moving a final line that lacks a trailing
// newline to a non-final slot would need one added — unimplemented, because
// every hand-edited family config ends in `\n`.

public extension Toml.Annotated {

    /// The `[[path]]` element blocks in document order — the header blocks
    /// only, not the sub-table blocks each element owns (see
    /// `blockRangesOfArrayOfTables`). Empty if there is no such array.
    func arrayOfTables(at path: [String]) -> [Block] {
        blockIndices(ofArrayOfTablesAt: path).map { blocks[$0] }
    }

    func arrayOfTablesCount(at path: [String]) -> Int {
        blockIndices(ofArrayOfTablesAt: path).count
    }

    /// Reorder the array-of-tables elements at `path`. `order` is a
    /// permutation of `0..<count`: the element currently at ordinal
    /// `order[k]` becomes the new ordinal `k`. Each element moves WHOLE —
    /// header, body, banner comment AND the sub-table blocks it owns
    /// (`[path.sub]`, `[[path.sub]]`, …) — so its nested tables stay bound to
    /// it. Unrelated blocks between elements keep their positions. An invalid
    /// permutation is a no-op, as is non-contiguous element ownership (see
    /// `arrayOfTablesOwnershipIsContiguous`).
    func reorderingArrayOfTables(at path: [String], _ order: [Int]) -> Self {
        guard arrayOfTablesOwnershipIsContiguous(at: path) else { return self }
        let ranges = blockRangesOfArrayOfTables(at: path)
        let n = ranges.count
        guard order.count == n, Set(order) == Set(0..<n) else { return self }
        let elements = ranges.map { Array(blocks[$0]) }
        var newBlocks: [Block] = []
        var k = 0
        var idx = 0
        while idx < blocks.count {
            if k < ranges.count && idx == ranges[k].lowerBound {
                newBlocks.append(contentsOf: elements[order[k]])
                idx = ranges[k].upperBound
                k += 1
            } else {
                newBlocks.append(blocks[idx])
                idx += 1
            }
        }
        var copy = self
        copy.blocks = newBlocks
        return copy
    }

    /// Remove the array-of-tables element at `ordinal` (0-based) under `path`,
    /// WHOLE — header, body, banner AND the sub-table blocks it owns;
    /// otherwise an orphaned `[path.sub]` would re-bind to the wrong element
    /// or fail to parse. An out-of-range ordinal is a no-op, as is
    /// non-contiguous ownership (see `arrayOfTablesOwnershipIsContiguous`).
    func removingArrayOfTablesElement(at path: [String], ordinal: Int) -> Self {
        guard arrayOfTablesOwnershipIsContiguous(at: path) else { return self }
        let ranges = blockRangesOfArrayOfTables(at: path)
        guard ranges.indices.contains(ordinal) else { return self }
        var copy = self
        copy.blocks.removeSubrange(ranges[ordinal])
        return copy
    }

    /// Remove the first `[path]` std-table block with its banner. No-op if
    /// absent. Sub-tables `[path.sub]` are left in place on purpose: they
    /// stay valid, re-rooting `path` as an implicit super-table.
    func removingTable(at path: [String]) -> Self {
        guard let i = blocks.firstIndex(where: { $0.kind == .table && $0.path == path })
        else { return self }
        var copy = self
        copy.blocks.remove(at: i)
        return copy
    }

    /// Set the value of an EXISTING entry in one `[[path]]` element.
    /// `ordinal` is 0-based document order; `key` is ONE literal key segment
    /// (NOT dotted-path syntax — a dotted entry `a.b = …` is never matched;
    /// the first duplicate wins, mirroring `Body.entry(forKey:)`). Only the
    /// value token is replaced — indent, key spelling, `=` spacing, the
    /// same-line comment and the terminator stay verbatim. The new value is
    /// spelled by `Toml.encode`, so a string always becomes a basic string
    /// whatever the old quoting style. A missing element / key is a no-op.
    func settingValue(_ value: Toml.Value, atArrayOfTablesElement path: [String],
                      ordinal: Int, forKey key: String) -> Self {
        let heads = blockIndices(ofArrayOfTablesAt: path)
        guard heads.indices.contains(ordinal) else { return self }
        let bi = heads[ordinal]
        guard let ei = blocks[bi].body.entries.firstIndex(where: { $0.key == [key] })
        else { return self }
        var copy = self
        copy.blocks[bi].body.entries[ei] =
            Self.settingRaw(blocks[bi].body.entries[ei], to: Toml.encode(value))
        return copy
    }

    /// Set-or-insert: like `settingValue(_:atArrayOfTablesElement:…)`, but a
    /// missing `key` is APPENDED after the element's last entry (before any
    /// trailing trivia), inheriting that sibling's indent + line terminator.
    /// A final sibling lacking a terminator gets one added — the one
    /// neighbouring byte an edit may touch. No-ops, never invalid TOML: a
    /// missing element (no element append — see the file head), and a `key`
    /// already defined another way — by a dotted sibling (`key.x = …`) or a
    /// sub-block the element owns (`[path.key]`).
    func upsertingValue(_ value: Toml.Value, inArrayOfTablesElement path: [String],
                        ordinal: Int, forKey key: String) -> Self {
        let ranges = blockRangesOfArrayOfTables(at: path)
        guard ranges.indices.contains(ordinal) else { return self }
        let bi = ranges[ordinal].lowerBound
        let token = Toml.encode(value)
        var copy = self
        if let ei = blocks[bi].body.entries.firstIndex(where: { $0.key == [key] }) {
            copy.blocks[bi].body.entries[ei] =
                Self.settingRaw(blocks[bi].body.entries[ei], to: token)
        } else {
            let owned = blocks[(bi + 1)..<ranges[ordinal].upperBound]
            guard !Self.appendCollides(key: key, body: blocks[bi].body,
                                       basePath: path, subBlocks: owned)
            else { return self }
            copy.blocks[bi].body = Self.appending(
                blocks[bi].body, key: key, token: token,
                fallbackTerminator: Self.terminator(of: blocks[bi].headerRaw))
        }
        return copy
    }

    /// Set-or-insert `key = [elements]` under the FIRST `[path]` std table.
    /// Same in-place / append semantics as `upsertingValue`; when no such
    /// table exists at all, a NEW block is created at the document end: one
    /// blank separator line (the block's `leading` — omitted in an empty
    /// document), a newline-terminated header, then the entry. No-ops, never
    /// invalid TOML: an empty `path`; a `key` already defined another way in
    /// the table (dotted entry / `[path.key]` sub-block); and — on the create
    /// path — a `path` that collides with an existing definition (an
    /// array-of-tables at any prefix, or a key-defined node a header cannot
    /// redefine or extend).
    func settingArrayValue(_ elements: [Toml.Value], atTable path: [String],
                           forKey key: String) -> Self {
        settingToken(Toml.encode(.array(elements)), atTable: path, forKey: key)
    }

    /// The scalar twin of `settingArrayValue` — same semantics, same no-op
    /// guards. It exists because a single `[path]` table (facet's
    /// `[desktop.N]`) is unreachable by the AoT-element ops.
    func settingValue(_ value: Toml.Value, atTable path: [String],
                      forKey key: String) -> Self {
        settingToken(Toml.encode(value), atTable: path, forKey: key)
    }

    /// Indices into `blocks` of the `[[path]]` element HEADERS, in document
    /// order — not the owned spans (`blockRangesOfArrayOfTables`).
    func blockIndices(ofArrayOfTablesAt path: [String]) -> [Int] {
        blocks.indices.filter { blocks[$0].kind == .arrayElement && blocks[$0].path == path }
    }

    /// The contiguous block range each `[[path]]` element OWNS: its header
    /// plus every following block whose path is a strict descendant of `path`
    /// (`[path.physical]`, `[[path.variety]]`, …), up to the next sibling
    /// element or any header that leaves the subtree. This is the unit
    /// reorder / delete moves, so nested tables stay bound to their element.
    func blockRangesOfArrayOfTables(at path: [String]) -> [Range<Int>] {
        let starts = blockIndices(ofArrayOfTablesAt: path)
        func isDescendant(_ b: Block) -> Bool {
            b.path.count > path.count && Array(b.path.prefix(path.count)) == path
        }
        var ranges: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            let hardEnd = (k + 1 < starts.count) ? starts[k + 1] : blocks.count
            var e = s + 1
            while e < hardEnd && isDescendant(blocks[e]) { e += 1 }
            ranges.append(s..<e)
        }
        return ranges
    }

    /// Whether every strict descendant block of the array-of-tables at `path`
    /// sits INSIDE one of the contiguous element ranges. False when an
    /// unrelated block is interleaved between an element's header and a
    /// sub-table it owns: TOML still binds that sub-table to the element by
    /// most-recent-definition, but the owned span
    /// (`blockRangesOfArrayOfTables`) stops at the unrelated block, so a
    /// structural move would leave the sub-table behind and re-bind it to the
    /// wrong element. Reorder / remove no-op in that case rather than risk
    /// silent corruption; value writes are unaffected. Every real family
    /// config places sub-tables directly after their header, so this never
    /// fires in practice.
    internal func arrayOfTablesOwnershipIsContiguous(at path: [String]) -> Bool {
        let ranges = blockRangesOfArrayOfTables(at: path)
        guard !ranges.isEmpty else { return true }
        for i in blocks.indices
        where blocks[i].path.count > path.count
            && Array(blocks[i].path.prefix(path.count)) == path {
            if !ranges.contains(where: { $0.contains(i) }) { return false }
        }
        return true
    }
}

// MARK: - Private raw-surgery helpers

private extension Toml.Annotated {

    /// The shared set-or-insert engine behind the two `atTable:` ops; `token`
    /// is already spelled by `Toml.encode`. The contract, including every
    /// no-op guard, is documented on `settingArrayValue`.
    func settingToken(_ token: String, atTable path: [String],
                      forKey key: String) -> Self {
        guard !path.isEmpty else { return self }
        var copy = self
        if let bi = blocks.firstIndex(where: { $0.kind == .table && $0.path == path }) {
            if let ei = blocks[bi].body.entries.firstIndex(where: { $0.key == [key] }) {
                copy.blocks[bi].body.entries[ei] =
                    Self.settingRaw(blocks[bi].body.entries[ei], to: token)
            } else {
                guard !Self.appendCollides(key: key, body: blocks[bi].body,
                                           basePath: path, subBlocks: blocks[...])
                else { return self }
                copy.blocks[bi].body = Self.appending(
                    blocks[bi].body, key: key, token: token,
                    fallbackTerminator: Self.terminator(of: blocks[bi].headerRaw))
            }
            return copy
        }
        // Create path. The second guard matters even though no `[path]` header
        // exists: a `[[path.key]]` / `[path.key]` / deeper block can still be
        // present, and the created `key = …` would duplicate that child.
        guard !Self.headerCollides(path: path, root: root, blocks: blocks),
              !Self.appendCollides(key: key, body: Body(), basePath: path, subBlocks: blocks[...])
        else { return self }
        let rendered = render()
        if !rendered.isEmpty && rendered.unicodeScalars.last != "\n" {
            // Scalar-level check: a CRLF end folds into one Character, so
            // hasSuffix("\n") would misfire and add a stray LF.
            if copy.blocks.isEmpty { copy.root.trailing += "\n" }
            else { copy.blocks[copy.blocks.count - 1].body.trailing += "\n" }
        }
        let header = "[" + path.map(Toml.encodeKey).joined(separator: ".") + "]\n"
        copy.blocks.append(Block(
            leading: rendered.isEmpty ? "" : "\n", kind: .table,
            headerRaw: header, path: path,
            body: Body(entries: [Self.makeEntry(key: key, valueToken: token,
                                                indent: "", newline: "\n")])))
        return copy
    }

    /// Replace ONLY the value token inside `entry.raw` — the crux of the set
    /// ops. The value span runs from the first non-space/tab after the `=`
    /// (found with the parser's own string-aware `lexFindEq`, so the two can
    /// never disagree) to the END of the last content token; strings are
    /// scanned whole, and `#` comments / whitespace never extend it. Bytes
    /// outside the span are re-emitted verbatim. Interior comments of a
    /// multi-line value sit INSIDE the span and go with the old value; the
    /// comment after the last content survives.
    static func settingRaw(_ entry: Entry, to token: String) -> Entry {
        let a = Array(entry.raw.unicodeScalars)
        guard let eq = Toml.lexFindEq(a) else { return entry }
        var start = eq + 1
        while start < a.count && (a[start] == " " || a[start] == "\t") { start += 1 }
        var i = start
        var end = start
        while i < a.count {
            let c = a[i]
            if c == "#" {
                while i < a.count && a[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" || c == "'" {
                let (next, _, _) = Toml.lexScanQuoted(a, i)
                end = min(next, a.count)
                i = next
                continue
            }
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
            i += 1
            end = i
        }
        var e = entry
        e.raw = String(String.UnicodeScalarView(a[0..<start])) + token
              + String(String.UnicodeScalarView(a[end...]))
        e.valueText = token
        return e
    }

    /// A fresh `key = token` entry. `key` is one literal segment, spelled
    /// through `encodeKey` so a non-bare key is quoted; no banner is
    /// fabricated.
    static func makeEntry(key: String, valueToken: String,
                          indent: String, newline: String) -> Entry {
        Entry(leading: "",
              raw: indent + Toml.encodeKey(key) + " = " + valueToken + newline,
              key: [key], valueText: valueToken)
    }

    /// Append `key = token` after `body`'s last entry — BEFORE its trailing
    /// trivia, so a blank-line separator stays put — inheriting the last
    /// sibling's indent and line terminator (an empty body uses no indent
    /// and `fallbackTerminator`, the block header's).
    static func appending(_ body: Body, key: String, token: String,
                          fallbackTerminator: String) -> Body {
        var b = body
        let indent: String
        let newline: String
        if let sib = b.entries.last {
            indent = String(String.UnicodeScalarView(
                Array(sib.raw.unicodeScalars).prefix { $0 == " " || $0 == "\t" }))
            newline = sib.raw.hasSuffix("\r\n") ? "\r\n" : "\n"
            if sib.raw.unicodeScalars.last != "\n" {
                // An unterminated final sibling (EOF) gets a terminator so the
                // new entry starts on its own line. Scalar-level check: "\r\n"
                // folds into ONE Character, so hasSuffix("\n") would treat a
                // CRLF sibling as unterminated and append a spurious blank.
                b.entries[b.entries.count - 1].raw += newline
            }
        } else {
            indent = ""
            newline = fallbackTerminator
        }
        b.entries.append(makeEntry(key: key, valueToken: token,
                                   indent: indent, newline: newline))
        return b
    }

    static func terminator(of headerRaw: String) -> String {
        headerRaw.hasSuffix("\r\n") ? "\r\n" : "\n"
    }

    /// Whether appending `key = …` into the body at `basePath` would render
    /// invalid TOML: a dotted sibling (`key.x = …` makes `key` a dotted-key
    /// table), or a sub-block at `basePath.key` or deeper among `subBlocks`.
    /// Pass the element's OWNED slice for an AoT element (a sub-header binds
    /// to its most recent element), or all blocks for a std table.
    static func appendCollides(key: String, body: Body, basePath: [String],
                               subBlocks: ArraySlice<Block>) -> Bool {
        if body.entries.contains(where: { $0.key.first == key }) { return true }
        return subBlocks.contains {
            $0.path.count > basePath.count
                && Array($0.path.prefix(basePath.count)) == basePath
                && $0.path[basePath.count] == key
        }
    }

    /// Whether creating a `[path]` header would render invalid TOML, or valid
    /// TOML bound to the WRONG place:
    ///   - an array-of-tables at any non-strict prefix of `path` — an exact
    ///     match is a redefinition; a strict prefix means the header would
    ///     bind inside the AoT's LAST element rather than at root;
    ///   - a KEY-defined node on `path`: within a scope `base` (root or a
    ///     block), an entry whose first key segment is `path`'s next segment
    ///     after `base` makes that node a scalar / inline table / dotted-key
    ///     table — all closed to headers.
    static func headerCollides(path p: [String], root: Body, blocks: [Block]) -> Bool {
        if blocks.contains(where: {
            $0.kind == .arrayElement && $0.path.count <= p.count
                && Array(p.prefix($0.path.count)) == $0.path
        }) { return true }
        func keyDefines(_ base: [String], _ body: Body) -> Bool {
            guard p.count > base.count, Array(p.prefix(base.count)) == base
            else { return false }
            return body.entries.contains { $0.key.first == p[base.count] }
        }
        if keyDefines([], root) { return true }
        return blocks.contains { keyDefines($0.path, $0.body) }
    }
}
