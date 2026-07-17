---
title: swift-toml-edit 用語集
tags: [glossary, swift, toml]
repo: swift-toml-edit
aliases: []
---

# 用語集 — swift-toml-edit

swift-toml-edit（STE）を構成するパーツの **正規の呼び名** をまとめた規範ドキュメント。
コード・ドキュメント・コミット・PR・Claude Code へのプロンプトすべてで、ここに載る名前を使う。
目的は **ユーザーと Claude Code の認識ズレ防止**。**正規名は英語のまま** 保持し（`Annotated`,
`parseFlat`, `SourceSpan` などコード識別子と一対一）、日本語化するのは説明文だけ。

STE は atelier 家系の **唯一の format-preserving TOML ライブラリ**（Swift の欠けている
toml_edit）。この用語集は **STE 固有の語** だけを定義する。config を編集する側の
**製品語彙**（facet の `isolate desktop` など）は複製せず、facet の用語集を正典として参照する:
<https://github.com/akira-toriyama/facet/blob/main/docs/glossary.md>。

## 2層アーキテクチャ

STE の中核は **1 つの lossless な DOM と、その上の lossy な射影** の二層。編集はすべて
lossless 層で行い、read API は lossy 層が sill の `Toml` と同名で再露出する。

- `Toml.swift` — lossy read projection（`parse` / `parseFlat` / `Value` / `Document`）。
- `Annotated.swift` — lossless な format-preserving DOM の型（block / entry / body / trivia）。
- `AnnotatedParse.swift` — 物理行を DOM へ畳む tiler（`lexLines` / `lexValueText`）。
- `AnnotatedEdit.swift` — functional な edit ops（reorder / remove / set / upsert）。
- `Lexer.swift` — string-aware な共有字句プリミティブ（M1→M2 で multi-line string 対応）。
- `ParseWithSpans.swift` — span つき strict engine（`parseWithSpans` → `SpannedTree`）。
- `Span.swift` — lossy `parse` 用の `SourceSpan` / `Row`（合成 `__line__` の後継）。
- `DecodeStrict.swift` / `TypedValue.swift` / `TypedTree.swift` — toml-test の strict decode 層。
- `Serialize.swift` / `TaggedJSON.swift` — toml-test の encoder ＋ tagged-JSON 出力。

## 規約

- **facet 製品語彙は複製しない**: config を編集する側の語（`isolate desktop` 等）は上の
  facet 用語集を正典として参照する。ここには STE 固有語だけを置く。
- **正規名は英語**（コード識別子と一対一）、説明は日本語。用語間は `[[wikilink]]` で相互参照。
- **用語の追加・改名はコード変更と同一 PR で反映する**（家族方針。glossary だけ後追いにしない）。
- Pages 化は `glossary-site` の reusable workflow（`.github/workflows/glossary.yml`）。
