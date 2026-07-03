# CLAUDE.md — swift-toml-edit

## What this is
- `swift-toml-edit` = the atelier family's ONE format-preserving TOML library
  (Swift's missing toml_edit / tomlkit). Module name is `Toml` (bare,
  idiomatic — like `Algorithms` / `OrderedCollections`). This is **Sill-1** of
  the atelier refactor: it REPLACES sill's lossy `Toml` module entirely, and the
  five consumers (perch / wand / chord / facet / ConfigSchema) migrate to it.
- Standalone OSS repo, NOT inside atelier — the EXPLICIT exception to the
  family's "no new repos" rule (correctness-critical, sill has no CI,
  self-contained, fills a real Swift OSS gap, clean end-state). Canonical
  design brief: atelier `docs/swift-toml-edit.md`. Progress tracker: atelier
  `docs/refactor.md` §Roadmap (Sill-1). Don't restate those here — link them.

## The mandate: format-preserving
- TOML config in this family is hand-curated — comments, ordering, blank lines,
  indentation and the `#:schema` pragma are load-bearing. The library MUST
  round-trip them. The first real need is editing array-of-tables blocks
  (`[[tome.item]]` / `[[cast.rule]]`) — reorder / delete — without disturbing
  surrounding formatting (wand#130 / facet DnD).

## Architecture: one lossless DOM + a lossy projection
- **Lossless `Toml.Annotated` DOM**: value-type (struct/enum), Sendable; each
  node carries its raw spelling + attached trivia. Editing is FUNCTIONAL —
  `reorderingArrayOfTables(...)` / `removing(...)` return a NEW document (Swift
  value semantics); no in-place mutation API. The DOM's node types are nested
  under `Annotated` (`Toml.Annotated.Table` / `.Value` / `.Key` / …) so they do
  not collide with the lossy `Toml.Value` / `Toml.Document` names.
- **Lossy projection**: re-exposes the read API under the SAME names sill's
  `Toml` had — `parse` (nested, strict), `parseFlat` (flat, lenient), `Value`,
  `Document`, the accessors. (Until the lossless parser passes full toml-test, the
  projection is the proven sill line-parser, ported verbatim; unifying it onto
  the lossless DOM is a later, gated step — before the consumer swap.)
  Source attribution: `parse`'s `Value.arrayOfTables` holds `[Row]` (each row's
  `fields` + the `[[header]]` `SourceSpan` — see `Span.swift`), NOT a bare
  `[[String: Value]]`. This replaced the old synthetic `__line__`/`lineKey`
  dict key (2.0.0) — a typed location that can't shadow a user key and rides
  on value-copy when a consumer clones a row. `parseFlat` keeps plain
  `[[String: Value]]` rows (its flat consumers don't attribute warnings).
- Edit ops are deliberately MINIMAL: AoT reorder/delete + serialize, and —
  since v2.1.0 (t-12az, facet's config auto-persist prereq) — per-element
  VALUE writes (`settingValue` / `upsertingValue` on one AoT element,
  `settingArrayValue` under a std table, values spelled via the public
  `Toml.encode`). From-scratch emit and APPENDING a whole new AoT element
  stay YAGNI — do not add them.

## Invariants (death-before-violation)
- **Round-trip byte-identity**: if you don't change a block, read→write is
  byte-for-byte identical; changing one block leaves every other block (and
  CRLF / BOM / mixed indentation) untouched.
- **Full format-preservation**: anything we can parse, we can round-trip. The
  lenient `parseFlat` "skip the bad line" behavior is reproduced in the LOSSY
  PROJECTION layer — the lossless parse is strict.
- **Trivia attribution**: comments and blank lines travel with the header block
  that immediately FOLLOWS them; leading file-level comments are document-level
  trivia (the wand#129 rule).
- **The daemon never writes config** (family rule): this library is
  String/DOM → String only — NO file IO. Edited output goes to the caller.
- **Zero-dep** (pure Swift + Foundation, no SwiftPM TOML dependency),
  **Sendable**, **clockless** (no wall-clock reads) — the family principles.

## This repo has REAL CI (unlike the rest of the family)
- sill has NO CI; the app repos only build/test a macOS .app via the shared
  composite action + a rolling-draft .zip release. Here correctness is the
  product, so CI is the gate: build+test on macOS AND Linux (`ci.yml`); the
  official `toml-test` conformance suite (the v1.0 coverage bar) against the
  in-package `toml-decode` / `toml-encode` executables, and the round-trip
  byte-identity goldens over the
  family's real configs (committed under `Tests/TomlTests/Fixtures`). The v1.0
  tag is cut only when conformance + byte-identity are fully passing.
- Linux is supported on purpose (Foundation-only, no AppKit) — keep the code
  `canImport(AppKit)`-free so the Linux + conformance jobs stay valid.

## Conventions inherited from the family
- Commits: gitmoji + Conventional Commits (`:emoji: type(scope): subject`),
  enforced by the reusable commit-lint and consumed by git-cliff for release
  notes. License: MIT.
- Respond to the maintainer in Japanese (code / identifiers stay in the
  existing English conventions).
- Implementation order is late-binding (per the brief): build the lib to v1.0
  against the family's real configs as goldens BEFORE swapping consumers; then
  swap all five in one wave; then remove sill's `Toml`; app write-back UX
  (wand#130 etc.) is separate product work, after.
