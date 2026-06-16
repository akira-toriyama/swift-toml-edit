// Functional edit ops — the minimal set the family needs (brief Q3): reorder
// and delete array-of-tables elements, plus delete a std table. Each returns a
// NEW document (value semantics); the receiver is unchanged. These are the
// "first real need": editing the AoT blocks behind wand's tome export (#130)
// and facet's drag-and-drop, writing the result back with formatting intact.
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
    /// no-op.
    func reorderingArrayOfTables(at path: [String], _ order: [Int]) -> Self {
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
    /// parse). An out-of-range ordinal is a no-op.
    func removingArrayOfTablesElement(at path: [String], ordinal: Int) -> Self {
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
}
