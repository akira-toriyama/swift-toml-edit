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
    /// `order[k]` becomes the new ordinal `k`. Each element moves whole, so
    /// its banner comment travels with it. The elements' positions in the
    /// document (relative to other tables) are preserved — only their order
    /// among themselves changes. An invalid permutation is a no-op.
    func reorderingArrayOfTables(at path: [String], _ order: [Int]) -> Self {
        let slots = blockIndices(ofArrayOfTablesAt: path)
        let n = slots.count
        guard order.count == n, Set(order) == Set(0..<n) else { return self }
        let elements = slots.map { blocks[$0] }
        var copy = self
        for (k, slot) in slots.enumerated() {
            copy.blocks[slot] = elements[order[k]]
        }
        return copy
    }

    /// Remove the array-of-tables element at `ordinal` (0-based) under `path`.
    /// The whole block — header, body, and attached leading trivia — is
    /// removed. An out-of-range ordinal is a no-op.
    func removingArrayOfTablesElement(at path: [String], ordinal: Int) -> Self {
        let slots = blockIndices(ofArrayOfTablesAt: path)
        guard slots.indices.contains(ordinal) else { return self }
        var copy = self
        copy.blocks.remove(at: slots[ordinal])
        return copy
    }

    /// Remove the first `[table]` (std-table) block at `path`, with its
    /// attached leading trivia. A no-op if there is no such table.
    func removingTable(at path: [String]) -> Self {
        guard let i = blocks.firstIndex(where: { $0.kind == .table && $0.path == path })
        else { return self }
        var copy = self
        copy.blocks.remove(at: i)
        return copy
    }

    /// Indices into `blocks` of the array-of-tables elements at `path`,
    /// in document order.
    func blockIndices(ofArrayOfTablesAt path: [String]) -> [Int] {
        blocks.indices.filter { blocks[$0].kind == .arrayElement && blocks[$0].path == path }
    }
}
