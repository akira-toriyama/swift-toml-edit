// Functional edit ops — the minimal set the family needs (brief Q3): reorder
// and delete array-of-tables elements, plus delete a std table. Each returns a
// NEW document (value semantics); the receiver is unchanged. These are the
// "first real need": editing the AoT blocks behind wand's tome export (#130)
// and facet's drag-and-drop, writing the result back with formatting intact.
//
// v2.1.0 adds the per-element VALUE ops — `settingValue` / `upsertingValue`
// on one `[[path]]` element and `settingArrayValue` under a `[path]` table —
// the surgical writes facet's config auto-persistence needs (t-12az): only
// the value token inside one entry's `raw` is rewritten (via `Toml.encode`),
// so comments / indent / spacing stay byte-verbatim. v2.3.0 adds the scalar
// twin `settingValue(_:atTable:forKey:)` for a single `[path]` table entry
// (facet's lens-desktop `[desktop.N] match`, t-sgqk) — same engine, same
// guards. Still out of scope: from-scratch emit, and APPENDING a whole new
// `[[path]]` element (facet skips + logs that case).
//
// Trivia on edit (the wand#129 rule): an element moves/deletes WHOLE — its
// banner comment travels with it (so a per-element comment never labels the
// wrong element), while blank-line SEPARATORS stay with the preceding block
// (they are parsed as its `body.trailing`), so spacing stays uniform.
// Caveats (cosmetic, and matching Rust toml_edit): a banner above the
// document's FIRST content token lives in the never-moving document `leading`,
// so it does not travel; and because there are N−1 separators between N
// elements, the element that lands LAST may gain/lose a trailing blank.
// Identity permutations are byte-stable. ASSUMES newline-terminated lines —
// true for every hand-edited family config (all end in `\n`); moving a final
// line that lacks a trailing newline to a non-final slot would need one added
// (handled when M2 adds separator normalization).

public extension Toml.Annotated {

    /// The array-of-tables elements at `path`, in document order (each is the
    /// `[[path]]` block — read `block.body` to inspect an element's fields,
    /// e.g. to decide a new order). Empty if there is no such array-of-tables.
    func arrayOfTables(at path: [String]) -> [Block] {
        blockIndices(ofArrayOfTablesAt: path).map { blocks[$0] }
    }

    /// Number of `[[path]]` elements.
    func arrayOfTablesCount(at path: [String]) -> Int {
        blockIndices(ofArrayOfTablesAt: path).count
    }

    /// Reorder the array-of-tables elements at `path`. `order` is a
    /// permutation of `0..<count`: the element currently at ordinal
    /// `order[k]` becomes the new ordinal `k`. Each element moves WHOLE —
    /// its `[[path]]` header, its body, its banner comment, AND any sub-table
    /// blocks it owns (`[path.sub]`, `[[path.sub]]`, …) travel together — so an
    /// element's nested tables stay bound to it. The elements' positions
    /// relative to unrelated blocks are preserved. An invalid permutation is a
    /// no-op — as is a path whose element ownership is non-contiguous (an
    /// unrelated block sits between an element's header and a sub-table it
    /// owns), where a clean move is impossible without stranding that
    /// sub-table (see `arrayOfTablesOwnershipIsContiguous`).
    func reorderingArrayOfTables(at path: [String], _ order: [Int]) -> Self {
        guard arrayOfTablesOwnershipIsContiguous(at: path) else { return self }
        let ranges = blockRangesOfArrayOfTables(at: path)
        let n = ranges.count
        guard order.count == n, Set(order) == Set(0..<n) else { return self }
        let elements = ranges.map { Array(blocks[$0]) }
        // Rebuild: emit the permuted element slice at each element's original
        // start, keeping any unrelated blocks between elements in place.
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

    /// Remove the array-of-tables element at `ordinal` (0-based) under `path`.
    /// The WHOLE element — its `[[path]]` header, body, attached leading
    /// trivia, AND any sub-table blocks it owns — is removed (otherwise an
    /// orphaned `[path.sub]` would re-bind to the wrong element or fail to
    /// parse). An out-of-range ordinal is a no-op — as is a path whose element
    /// ownership is non-contiguous (see `arrayOfTablesOwnershipIsContiguous`),
    /// where removing the contiguous slice would strand an owned sub-table.
    func removingArrayOfTablesElement(at path: [String], ordinal: Int) -> Self {
        guard arrayOfTablesOwnershipIsContiguous(at: path) else { return self }
        let ranges = blockRangesOfArrayOfTables(at: path)
        guard ranges.indices.contains(ordinal) else { return self }
        var copy = self
        copy.blocks.removeSubrange(ranges[ordinal])
        return copy
    }

    /// Remove the first `[table]` (std-table) block at `path`, with its
    /// attached leading trivia. A no-op if there is no such table. (Sub-tables
    /// `[path.sub]` are left in place; they remain valid, re-rooting `path` as
    /// an implicit super-table.)
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
    /// value token inside the entry's `raw` is replaced: indent, key
    /// spelling, `=` spacing, the same-line comment and the terminator stay
    /// verbatim. The new value is spelled by `Toml.encode` — a string always
    /// becomes a basic string, whatever the old quoting style. A missing
    /// element / key is a no-op.
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
    /// trailing trivia), inheriting that sibling's indent + line terminator
    /// (facet: give an unnamed workspace section a `label`). A final sibling
    /// lacking a terminator gets one added — the one neighbouring byte an
    /// edit may touch. No-ops, never invalid TOML: a missing element
    /// (appending a whole new `[[path]]` element is out of scope, v2.1.0),
    /// and a `key` already defined another way — by a dotted sibling
    /// (`key.x = …`) or a sub-block the element owns (`[path.key]`).
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

    /// Set-or-insert `key = [elements]` under the FIRST `[path]` std table —
    /// facet's `[tags] defined = […]`. Same in-place / append semantics as
    /// `upsertingValue`; when no such table exists at all, a NEW block is
    /// created at the document end: one blank separator line (the block's
    /// `leading` — omitted in an empty document), a newline-terminated
    /// header, then the entry. No-ops, never invalid TOML: an empty `path`;
    /// a `key` already defined another way in the table (dotted entry /
    /// `[path.key]` sub-block); and — on the create path — a `path` that
    /// collides with an existing definition (an array-of-tables at any
    /// prefix, or a key-defined node a header cannot redefine or extend).
    func settingArrayValue(_ elements: [Toml.Value], atTable path: [String],
                           forKey key: String) -> Self {
        settingToken(Toml.encode(.array(elements)), atTable: path, forKey: key)
    }

    /// Set-or-insert `key = value` (one SCALAR entry) under the FIRST `[path]`
    /// std table — the scalar twin of `settingArrayValue`, and the write facet's
    /// config auto-persistence needs for a lens desktop's live-retargeted
    /// `[desktop.N] match = "…"` (t-sgqk; `[desktop.N]` is a SINGLE table, so
    /// the AoT-element ops can't reach it). Identical semantics + no-op guards;
    /// the value is spelled by `Toml.encode`, so a string always becomes a
    /// basic string, whatever the old quoting style.
    func settingValue(_ value: Toml.Value, atTable path: [String],
                      forKey key: String) -> Self {
        settingToken(Toml.encode(value), atTable: path, forKey: key)
    }

    /// Indices into `blocks` of the array-of-tables ELEMENT HEADERS at `path`,
    /// in document order. (Use `blockRangesOfArrayOfTables` to get each
    /// element's full owned span, header + sub-tables.)
    func blockIndices(ofArrayOfTablesAt path: [String]) -> [Int] {
        blocks.indices.filter { blocks[$0].kind == .arrayElement && blocks[$0].path == path }
    }

    /// The contiguous block range each `[[path]]` element OWNS, in document
    /// order: its header block plus every following block whose header path is a
    /// strict descendant of `path` (e.g. `[path.physical]`, `[[path.variety]]`),
    /// up to the next sibling `[[path]]` element or any header that leaves the
    /// subtree. This is the unit reorder/delete moves so nested tables stay
    /// bound to their element.
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

    /// Whether every block that is a strict descendant of the array-of-tables
    /// at `path` (a sub-table `[path.x]` / `[[path.x]]` / deeper that an element
    /// owns) sits INSIDE one of the contiguous element ranges. It is false when
    /// an unrelated block is interleaved between an element's header and a
    /// sub-table it owns: TOML binds that sub-table to the element by
    /// most-recent-definition regardless of the intervening block, but the
    /// element's owned span (`blockRangesOfArrayOfTables`) is a contiguous run
    /// that stops at the unrelated block — so a structural move (reorder /
    /// remove) would leave the sub-table behind, re-binding it to the wrong
    /// element (invalid TOML or silent corruption). The structural ops no-op
    /// when this is false rather than risk that; a plain edit / value write is
    /// unaffected. (Sub-tables placed immediately after their header — every
    /// real family config — are contiguous, so this never fires in practice.)
    /// Internal: an implementation detail of the reorder/remove no-op guard,
    /// not part of the public edit API.
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

// MARK: - Private raw-surgery helpers (the v2.1.0 value ops)

private extension Toml.Annotated {

    /// The shared set-or-insert engine behind `settingValue(_:atTable:forKey:)`
    /// and `settingArrayValue(_:atTable:forKey:)` — `token` is the value
    /// already spelled by `Toml.encode`. In-place value-token surgery when
    /// `key` exists in the FIRST `[path]` table; append when the table exists
    /// without it; a NEW `[path]` block at the document end when no such table
    /// exists — with the no-op guards both public docs describe.
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
        // No `[path]` anywhere → append a new std-table block at the end —
        // unless the header would redefine or extend an existing definition
        // (invalid TOML, or an AoT-bound header), OR the appended `key` would
        // collide with an existing CHILD block at `path.key` (a `[[path.key]]`
        // / `[path.key]` / deeper block that exists even though no `[path]`
        // header does): the created `key = …` then duplicates that child.
        // Either renders invalid TOML, so no-op instead.
        guard !Self.headerCollides(path: path, root: root, blocks: blocks),
              !Self.appendCollides(key: key, body: Body(), basePath: path, subBlocks: blocks[...])
        else { return self }
        let rendered = render()
        if !rendered.isEmpty && rendered.unicodeScalars.last != "\n" {
            // The document's final line has no terminator — add one so the
            // new header starts on its own line. (Scalar-level check: a CRLF
            // end folds into one Character, so hasSuffix("\n") would misfire.)
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
    /// ops. The assignment `=` is found with the same string-aware scan the
    /// parser uses (`lexFindEq` — a `#` never precedes it in a valid entry);
    /// the value span runs from the first non-space/tab after it to the END
    /// of the last content token (strings scanned whole via `lexScanQuoted`,
    /// `#` comments and whitespace never extend it). Everything before and
    /// after the span — indent, key spelling, `=` spacing, the same-line
    /// comment, the terminator — is re-emitted verbatim. Interior comments of
    /// a multi-line value sit INSIDE the span, so they are replaced with the
    /// old value; the comment after the last content survives.
    static func settingRaw(_ entry: Entry, to token: String) -> Entry {
        let a = Array(entry.raw.unicodeScalars)
        guard let eq = Toml.lexFindEq(a) else { return entry }
        var start = eq + 1
        while start < a.count && (a[start] == " " || a[start] == "\t") { start += 1 }
        var i = start
        var end = start                              // end of the last content token
        while i < a.count {
            let c = a[i]
            if c == "#" {                            // comment → never content
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

    /// A fresh `key = token` entry with the given surrounding style. `key`
    /// is one literal segment, spelled through `encodeKey` (quoted when not
    /// a bare key); no banner is fabricated (`leading` stays empty).
    static func makeEntry(key: String, valueToken: String,
                          indent: String, newline: String) -> Entry {
        Entry(leading: "",
              raw: indent + Toml.encodeKey(key) + " = " + valueToken + newline,
              key: [key], valueText: valueToken)
    }

    /// Append `key = token` after `body`'s last entry — before its trailing
    /// trivia, so a blank-line separator stays put — inheriting the last
    /// sibling's indent and line terminator. An empty body uses no indent and
    /// `fallbackTerminator` (the block header's). A final sibling with no
    /// terminator (EOF) gets one added first so the new entry starts on its
    /// own line.
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
                // Scalar-level check — "\r\n" folds into ONE Character, so
                // hasSuffix("\n") would treat a CRLF-terminated sibling as
                // unterminated and append a spurious blank line.
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

    /// The line-terminator style of a header line (`\r\n` or `\n`).
    static func terminator(of headerRaw: String) -> String {
        headerRaw.hasSuffix("\r\n") ? "\r\n" : "\n"
    }

    /// Whether appending an entry `key = …` into the body at `basePath`
    /// would COLLIDE with an existing definition and render invalid TOML:
    /// a dotted sibling entry (`key.x = …` — `key` is a dotted-key table),
    /// or a sub-block at `basePath.key` (or deeper) among `subBlocks` —
    /// pass the element's OWNED block slice for an AoT element (a sub-header
    /// binds to its most recent element), or all blocks for a std table.
    static func appendCollides(key: String, body: Body, basePath: [String],
                               subBlocks: ArraySlice<Block>) -> Bool {
        if body.entries.contains(where: { $0.key.first == key }) { return true }
        return subBlocks.contains {
            $0.path.count > basePath.count
                && Array($0.path.prefix(basePath.count)) == basePath
                && $0.path[basePath.count] == key
        }
    }

    /// Whether creating a `[path]` header would redefine or extend an
    /// existing definition — i.e. the render would be invalid TOML (or, for
    /// the AoT-prefix case, valid but bound to the WRONG place):
    ///   - an array-of-tables at any non-strict prefix of `path` (an exact
    ///     match is a redefinition; a strict prefix means the header would
    ///     bind inside the AoT's LAST element rather than at root);
    ///   - a KEY-defined node on `path`: within a scope `base` (the root or
    ///     a block), an entry whose first key segment is `path`'s next
    ///     segment after `base` makes that node a scalar / inline table /
    ///     dotted-key table — all closed to headers.
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
