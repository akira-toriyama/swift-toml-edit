---
title: swift-toml-edit glossary
tags: [glossary, swift, toml]
repo: swift-toml-edit
aliases: []
---

# Glossary — swift-toml-edit

The normative document collecting the **canonical names** of every part of
swift-toml-edit (STE). Code, documentation, commit messages, PR titles, and
prompts to Claude Code all use the names listed here. The goal is to keep the
user and Claude Code from drifting apart on what a thing is called. Canonical
names are 1:1 with code identifiers (`Annotated`, `parseFlat`, `SourceSpan`, …).

STE is the atelier family's **one format-preserving TOML library** (Swift's
missing toml_edit). This glossary defines **STE-specific terms only**. The
**product vocabulary** of the config-editing side (facet's `isolate desktop`
and friends) is not duplicated here; facet's glossary is the canon for it:
<https://github.com/akira-toriyama/facet/blob/main/docs/glossary.md>.

## Two-layer architecture

STE's core is **one lossless DOM with a lossy projection on top**. All editing
happens in the lossless layer; the lossy layer re-exposes the read API under the
same names sill's `Toml` had.

- `Toml.swift` — lossy read projection (`parse` / `parseFlat` / `Value` / `Document`).
- `Annotated.swift` — the lossless format-preserving DOM types (block / entry / body / trivia).
- `AnnotatedParse.swift` — the tiler folding physical lines into the DOM (`lexLines` / `lexValueText`).
- `AnnotatedEdit.swift` — functional edit ops (reorder / remove / set / upsert).
- `Lexer.swift` — shared string-aware lexical primitives (multi-line strings arrived with M1→M2).
- `ParseWithSpans.swift` — the strict engine with spans (`parseWithSpans` → `SpannedTree`).
- `Span.swift` — `SourceSpan` / `Row` for the lossy `parse` (successor of the synthetic `__line__`).
- `DecodeStrict.swift` / `TypedValue.swift` / `TypedTree.swift` — the strict decode layer for toml-test.
- `Serialize.swift` / `TaggedJSON.swift` — the encoder plus tagged-JSON output for toml-test.

## Rules

- **Do not duplicate facet's product vocabulary**: terms of the config-editing
  side (`isolate desktop` etc.) point to facet's glossary above as the canon.
  Only STE-specific terms live here.
- **Canonical names are 1:1 with code identifiers.** Terms cross-reference each
  other with `[[wikilink]]`s.
- **Adding or renaming a term lands in the same PR as the code change** (family
  rule; the glossary never trails behind).
- Pages publishing goes through `glossary-site`'s reusable workflow
  (`.github/workflows/glossary.yml`).

## Core terms

### format-preserving
STE's central principle: anything that parses round-trips byte for byte.
Config is a hand-curated asset (comments, ordering, blank lines, indentation,
the `#:schema` pragma), and those carry meaning, so they must survive.
- Code: Annotated.swift, RoundTripTests.swift
- Related: [[byte-identity]] [[full format-preservation]] [[trivia]]

### byte-identity
A block you do not change reads and writes back one byte identical. Changing
one block leaves every other block (and CRLF / BOM / mixed indentation)
untouched. The strongest round-trip invariant.
- Code: RoundTripTests.swift
- Related: [[format-preserving]]

### full format-preservation
A restatement of "anything that parses round-trips". The lenient
"skip the broken line" behaviour is reproduced only in the lossy projection
layer; the lossless parse is strict.
- Code: Toml.swift, Annotated.swift
- Related: [[format-preserving]] [[lossy projection]]

### trivia
The raw whitespace and comments attached to a block. Split into leading and
trailing, restored byte for byte on render (the carrier of byte-identity).
- Code: Annotated.swift, AnnotatedParse.swift
- Related: [[trivia attribution]] [[format-preserving]] [[block]]

### trivia attribution
The rule for which block a comment or blank line belongs to: it attaches to
the **header block that immediately follows** (leading file-level comments are
document-level trivia). Settled in wand#129.
- Code: AnnotatedParse.swift
- Related: [[trivia]] [[block]]

### lossless Annotated DOM
The lossless document model: value types (struct / enum), Sendable, every node
carrying its raw spelling plus attached trivia. Editing happens here; the types
nest under `Toml.Annotated`.
- Code: Annotated.swift, AnnotatedParse.swift
- Related: [[lossy projection]] [[block]] [[edit ops]]

### lossy projection
The layer re-exposing the read API under the names sill's `Toml` had
(`parse` / `parseFlat` / `Value` / `Document`). For config reads that only want
values: no datetimes, integer radixes folded away.
- Code: Toml.swift
- Related: [[lossless Annotated DOM]] [[parse]] [[parseFlat]]

### block
The structural unit of the lossless DOM (one table, one array-of-tables
element, or the top-level group). Has a header, a body, and attached trivia;
edit ops operate on this unit.
- Code: Annotated.swift
- Related: [[entry]] [[body]] [[trivia]]

### entry
One `key = value` binding inside a block's body. Holds `valueText` (the raw
spelling of the value) and `value` (on-demand decoding into the lossy
`Toml.Value`).
- Code: Annotated.swift
- Related: [[block]] [[body]]

### body
The contents of a block: `entries` plus trailing trivia (`trailing`). Leading
trivia belongs to the block / entry that follows it, never to the body.
- Code: Annotated.swift
- Related: [[block]] [[entry]] [[trivia]]

### parse
The nested, strict read (chord's path). Folds dotted keys, nests
array-of-tables, and turns each AoT row into a `Row` with a `SourceSpan`.
Delegates to [[parseWithSpans]] since v3.
- Code: Toml.swift, ParseWithSpans.swift
- Related: [[parseFlat]] [[parseWithSpans]] [[Row]]

### parseFlat
The flat, lenient read (the facet / perch / wand path). Keys by literal header
name and drops only the one broken line, reading the rest. A line scanner by
design.
- Code: Toml.swift
- Related: [[parse]] [[lossy projection]]

### parseWithSpans
The strict engine proper. Derives the nested tree from the lossless DOM and
attaches line+column spans (`SpannedTree`), for chord's column-precise
`(config.toml:N:C)` warnings.
- Code: ParseWithSpans.swift
- Related: [[parse]] [[SpannedTree]] [[EntrySpans]]

### SpannedTree
The output of `parseWithSpans`: the nested tree together with per-entry /
per-header line+column spans.
- Code: ParseWithSpans.swift
- Related: [[parseWithSpans]] [[EntrySpans]]

### EntrySpans
The location of one entry (the key span and the value span). Held by
`SpannedTree`.
- Code: ParseWithSpans.swift
- Related: [[SpannedTree]] [[parseWithSpans]]

### Row
One AoT row as held by `parse`'s `Value.arrayOfTables`. Carries the row's
`fields` and the `SourceSpan` of its AoT header line (a typed location, not a
synthetic dict key).
- Code: Span.swift, Toml.swift
- Related: [[SourceSpan]] [[AoT]] [[parse]]

### SourceSpan
A typed source location for warning attribution. Cannot shadow a user key and
rides along when a row is copied.
- Code: Span.swift
- Related: [[Row]] [[parseWithSpans]]

### tiler
The scanner that classifies physical lines and folds them into lossless
blocks. Owns structure and byte-faithful round-tripping only; semantic checks
(redefinition and the like) belong to the strict decode layer.
- Code: AnnotatedParse.swift
- Related: [[lexLines]] [[lexValueText]] [[block]]

### lexLines
Scalar-based physical line splitting. Avoids the trap of `Character` folding
`\r\n` into one character, so CRLF documents split correctly (the t-b9ws fix).
Shared by `parse` and `parseFlat`.
- Code: AnnotatedParse.swift, Lexer.swift
- Related: [[tiler]] [[lexValueText]]

### lexValueText
The lexical primitive extracting the comment-stripped, trimmed value text. The
strict decoder's input.
- Code: Lexer.swift, DecodeStrict.swift
- Related: [[tiler]] [[lexLines]] [[TypedValue]]

### M1
An STE milestone name. M1 = the first tiler, classifying lines independently
(no multi-line string support).
- Code: AnnotatedParse.swift
- Related: [[M2]] [[tiler]]

### M2
An STE milestone name. M2 = the stage that added lexing across multi-line
strings plus toml-test strict decode / encode.
- Code: Lexer.swift, DecodeStrict.swift
- Related: [[M1]] [[lexValueText]] [[conformance]]

### AoT
Short for array-of-tables: TOML's double-bracket header, where repeating the
same header builds a sequence of elements.
- Code: Toml.swift, AnnotatedEdit.swift
- Related: [[Row]] [[edit ops]]

### orphan
**A general TOML term.** The state where removing an AoT parent element leaves
the `[path.sub]` sub-tables it owned stranded without a parent. Edit ops
remove an element **whole** (together with the sub-blocks it owns) to prevent
this.
**Not the same as the product-vocabulary "orphan" facet retired (the Lost &
Found section)**: a mechanical rename that conflates the two regresses (it
nearly slipped in during t-jx57).
- Code: AnnotatedEdit.swift, ReviewFixesTests.swift
- Related: [[AoT]] [[edit ops]]

### Toml.Value
The lossy, **frozen** consumer-facing value model. The projection the five
consumers import: no datetimes, integer radixes folded into `.int` (enough for
the apps).
- Code: Toml.swift
- Related: [[TypedValue]] [[lossy projection]]

### TypedValue
The strict, fully typed value model (the output of toml-test decode).
Distinguishes the four datetime kinds and keeps radixes. Distinct from
`Toml.Value`.
- Code: TypedValue.swift, DecodeStrict.swift
- Related: [[Toml.Value]] [[conformance]] [[tagged-JSON]]

### redefinition state machine
The state machine enforcing TOML 1.0's table / key redefinition semantics
(duplicate tables, reopening dotted-key tables, array-over-table clashes). A
decode-layer responsibility, not the tiler's.
- Code: TypedTree.swift
- Related: [[TypedValue]] [[conformance]]

### conformance
Compliance with the official `toml-test` suite (the v1.0 coverage bar). CI
runs both directions, decoder and encoder.
- Code: DecodeStrict.swift, Serialize.swift
- Related: [[TypedValue]] [[tagged-JSON]] [[golden]]

### tagged-JSON
toml-test's wire format: every scalar is `{"type": <tag>, "value": <string>}`
(the value is always a JSON string). Used to verify the encoder.
- Code: TaggedJSON.swift
- Related: [[conformance]] [[TypedValue]]

### edit ops
The minimal set of edit operations on the lossless DOM
(`reorderingArrayOfTables` / `removing…` / `settingValue` / `upsertingValue` /
`settingArrayValue`). **Functional** (each returns a new document — value
semantics, no in-place mutation) and deliberately minimal (YAGNI).
- Code: AnnotatedEdit.swift
- Related: [[lossless Annotated DOM]] [[AoT]] [[block]]

### golden
Regression material vendored from the family's real configs. Measures
byte-identity of unchanged blocks against real files. Drift (a real config
changes and the golden goes stale) is tracked separately.
- Code: RoundTripTests.swift
- Related: [[fixture]] [[byte-identity]]

### fixture
An input file under `Tests/TomlTests/Fixtures/`. Covers both vendored copies
of real configs (goldens) and hand-written inputs for edit ops.
- Code: RoundTripTests.swift, EditTests.swift
- Related: [[golden]] [[edit ops]]

### Sill-1
STE's place in the atelier refactor: the first wave, **replacing sill's lossy
`Toml` module entirely**, with the five consumers (perch / wand / chord / facet
/ ConfigSchema) migrating to it.
- Code: (the whole repository)
- Related: [[atelier family]] [[lossy projection]]

### atelier family
The group of projects in the wand lineage that includes STE. STE is their
shared TOML foundation.
- Related: [[Sill-1]]

## Retired terms

Retired STE-specific terms. The heading keeps the canonical name;
`deprecated::` records the version that retired it.

### __line__
deprecated:: 2.0.0
The retired synthetic dict key (earlier name `lineKey`). It embedded the line
number for warning attribution into each AoT row, but it could shadow a user
key and had to be skipped on every row iteration: a leaky abstraction.
Replaced in 2.0.0 by [[Row]] plus [[SourceSpan]] (a typed location).
- Code: Span.swift
- Related: [[Row]] [[SourceSpan]]

### line-based strict scanner
deprecated:: 3.0.0
The retired line-based scanner of the old strict parse. Removed in v3.0.0 when
`parse` started delegating to [[parseWithSpans]] (one derivation from the
lossless DOM). Its strictness contract — CRLF correctness, rejecting
triple-quoted spellings, and the rest of the tiler's rules — carried over
unchanged.
- Code: ParseWithSpans.swift
- Related: [[parseWithSpans]] [[parse]]
