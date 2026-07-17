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

## コア用語

### format-preserving
parse できたものは必ず byte 単位で round-trip できる、という STE の中核原則。
config は人が手で整える資産（コメント・順序・空行・インデント・`#:schema` プラグマ）で、
それらは意味を持つので保存されねばならない。
- コード: Annotated.swift, RoundTripTests.swift
- 関連: [[byte-identity]] [[full format-preservation]] [[trivia]]

### byte-identity
変更しない block は read→write で 1 バイト同一。ある block を変えても、他の block
（および CRLF / BOM / 混在インデント）は一切触れない。round-trip の最も強い不変条件。
- コード: RoundTripTests.swift
- 関連: [[format-preserving]]

### full format-preservation
parse できるものは round-trip できる、の言い換え。lenient な「壊れた行を飛ばす」挙動は
lossy 射影の層だけで再現し、lossless parse は strict。
- コード: Toml.swift, Annotated.swift
- 関連: [[format-preserving]] [[lossy projection]]

### trivia
block に付随する raw な空白・コメント。leading / trailing に分かれ、render で 1 バイト
単位に復元される（byte-identity の担い手）。
- コード: Annotated.swift, AnnotatedParse.swift
- 関連: [[trivia attribution]] [[format-preserving]] [[block]]

### trivia attribution
コメント・空行がどの block に属するかの規則: それらは **直後に続く header block** に付く
（先頭のファイルレベルのコメントは document レベル trivia）。wand#129 で確定したルール。
- コード: AnnotatedParse.swift
- 関連: [[trivia]] [[block]]

### lossless Annotated DOM
value 型（struct / enum）・Sendable で、各 node が raw spelling ＋ 付随 trivia を持つ
無損失の文書モデル。編集はここで行い、`Toml.Annotated` 配下に型がネストする。
- コード: Annotated.swift, AnnotatedParse.swift
- 関連: [[lossy projection]] [[block]] [[edit ops]]

### lossy projection
sill の `Toml` と同名の read API（`parse` / `parseFlat` / `Value` / `Document`）を
再露出する層。値だけが欲しい config 読み取り用で、datetime を持たず整数の基数を畳む。
- コード: Toml.swift
- 関連: [[lossless Annotated DOM]] [[parse]] [[parseFlat]]

### block
lossless DOM の構造単位（1 つの table / array-of-tables 要素 / トップレベル群）。
header・body・付随 trivia を持ち、edit ops はこの単位で動く。
- コード: Annotated.swift
- 関連: [[entry]] [[body]] [[trivia]]

### entry
block の body 内の 1 つの `key = value` 束縛。`valueText`（値の raw 綴り）と
`value`（lossy `Toml.Value` への on-demand デコード）を持つ。
- コード: Annotated.swift
- 関連: [[block]] [[body]]

### body
block の中身。`entries` と末尾 trivia（`trailing`）から成る。leading trivia は直後の block / entry 側が持つ（body には無い）。
- コード: Annotated.swift
- 関連: [[block]] [[entry]] [[trivia]]

### parse
nested・strict な読み（chord 経路）。dotted key を畳み、array-of-tables をネストして扱い、
各 AoT 行を `SourceSpan` つき `Row` にする。v3 で [[parseWithSpans]] に委譲。
- コード: Toml.swift, ParseWithSpans.swift
- 関連: [[parseFlat]] [[parseWithSpans]] [[Row]]

### parseFlat
flat・lenient な読み（facet / perch / wand 経路）。リテラルなヘッダ名でキーし、壊れた
行は 1 行だけ落として残りを読む。設計上 line scanner のまま。
- コード: Toml.swift
- 関連: [[parse]] [[lossy projection]]

### parseWithSpans
strict engine の本体。lossless DOM から nested tree を導出し、行＋列スパンを付ける
（`SpannedTree`）。chord の列精密な `(config.toml:N:C)` 警告のためのもの。
- コード: ParseWithSpans.swift
- 関連: [[parse]] [[SpannedTree]] [[EntrySpans]]

### SpannedTree
`parseWithSpans` の出力。nested tree に per-entry / per-header の行＋列スパンを併せ持つ。
- コード: ParseWithSpans.swift
- 関連: [[parseWithSpans]] [[EntrySpans]]

### EntrySpans
1 エントリの位置情報（key と value のスパン）。`SpannedTree` が保持する。
- コード: ParseWithSpans.swift
- 関連: [[SpannedTree]] [[parseWithSpans]]

### Row
`parse` の `Value.arrayOfTables` が持つ AoT 1 行。行の `fields` と、その AoT ヘッダ行の
`SourceSpan` を持つ（合成 dict キーではなく型付き位置）。
- コード: Span.swift, Toml.swift
- 関連: [[SourceSpan]] [[AoT]] [[parse]]

### SourceSpan
警告帰属のための型付きソース位置。user キーを shadow せず、行のコピーに乗る。
- コード: Span.swift
- 関連: [[Row]] [[parseWithSpans]]

### tiler
物理行を分類し lossless な block へ畳む scanner。構造と byte 忠実な round-trip だけを
受け持ち、意味的な検査（再定義など）は strict decode 層に任せる。
- コード: AnnotatedParse.swift
- 関連: [[lexLines]] [[lexValueText]] [[block]]

### lexLines
scalar ベースの物理行分割。`Character` が `\r\n` を 1 文字に畳む罠を避け、CRLF 文書を
正しく行分割する（t-b9ws の修正）。`parse` と `parseFlat` の両方がこれを共有する。
- コード: AnnotatedParse.swift, Lexer.swift
- 関連: [[tiler]] [[lexValueText]]

### lexValueText
コメント除去・trim 済みの値テキストを抽出する字句プリミティブ。strict decoder の入力。
- コード: Lexer.swift, DecodeStrict.swift
- 関連: [[tiler]] [[lexLines]] [[TypedValue]]

### M1
STE のマイルストン名。M1 = 行を独立に分類する初代 tiler（multi-line string 非対応）。
- コード: AnnotatedParse.swift
- 関連: [[M2]] [[tiler]]

### M2
STE のマイルストン名。M2 = multi-line string を跨ぐ字句と、toml-test の strict decode /
encode を足した段階。
- コード: Lexer.swift, DecodeStrict.swift
- 関連: [[M1]] [[lexValueText]] [[conformance]]

### AoT
array-of-tables の略。TOML の二重角括弧ヘッダで、同名ヘッダの繰り返しが要素列になる。
- コード: Toml.swift, AnnotatedEdit.swift
- 関連: [[Row]] [[edit ops]]

### orphan
**TOML 一般語**。AoT 親要素の削除で、それが所有していた `[path.sub]` サブテーブルが
親を失って取り残される状態。edit ops は要素を **丸ごと**（所有するサブブロックごと）
削除してこれを防ぐ。
**facet が撤去した製品語彙の "orphan"（Lost & Found セクション）とは別物** —— 機械的な
rename で両者を混同すると回帰する（t-jx57 で実際に紛れかけた）。
- コード: AnnotatedEdit.swift, ReviewFixesTests.swift
- 関連: [[AoT]] [[edit ops]]

### Toml.Value
lossy・**凍結**された consumer 向け値モデル。5 つの consumer が import する射影で、
datetime を持たず整数の基数を `.int` に畳む（アプリはそれで足りる）。
- コード: Toml.swift
- 関連: [[TypedValue]] [[lossy projection]]

### TypedValue
strict・完全型付きの値モデル（toml-test decode の出力）。4 種の datetime を区別し
基数を保つ。`Toml.Value` とは別物。
- コード: TypedValue.swift, DecodeStrict.swift
- 関連: [[Toml.Value]] [[conformance]] [[tagged-JSON]]

### redefinition state machine
TOML 1.0 の table / key 再定義セマンティクス（重複テーブル・dotted-key テーブルの
再オープン・array-over-table 衝突）を強制する状態機械。tiler ではなく decode 層の責務。
- コード: TypedTree.swift
- 関連: [[TypedValue]] [[conformance]]

### conformance
公式 `toml-test` スイートに対する適合（v1.0 カバレッジのバー）。decoder と encoder の
両方向を CI で回す。
- コード: DecodeStrict.swift, Serialize.swift
- 関連: [[TypedValue]] [[tagged-JSON]] [[golden]]

### tagged-JSON
toml-test のワイヤ形式。各スカラーを `{"type": <tag>, "value": <string>}` で表す
（値は常に JSON 文字列）。encoder 検証で使う。
- コード: TaggedJSON.swift
- 関連: [[conformance]] [[TypedValue]]

### edit ops
lossless DOM 上の最小の編集操作群（`reorderingArrayOfTables` / `removing…` /
`settingValue` / `upsertingValue` / `settingArrayValue`）。**functional**（新しい
document を返す＝値意味論、in-place mutation なし）で、意図的に minimal（YAGNI）。
- コード: AnnotatedEdit.swift
- 関連: [[lossless Annotated DOM]] [[AoT]] [[block]]

### golden
家族の実 config を vendor した回帰検知素材。変更しない block の byte-identity を実ファイルに
対して測る。drift（実 config が変わって golden が古くなる問題）は別途追跡。
- コード: RoundTripTests.swift
- 関連: [[fixture]] [[byte-identity]]

### fixture
`Tests/TomlTests/Fixtures/` に置く入力ファイル。実 config の vendor コピー（golden）と、
edit ops 用の手書き入力の両方を含む。
- コード: RoundTripTests.swift, EditTests.swift
- 関連: [[golden]] [[edit ops]]

### Sill-1
atelier リファクタにおける STE の位置づけ。sill の lossy `Toml` モジュールを **丸ごと
置換** する第 1 弾で、5 consumer（perch / wand / chord / facet / ConfigSchema）が移行する。
- コード: (リポジトリ全体)
- 関連: [[atelier family]] [[lossy projection]]

### atelier family
STE を含む wand 家系のプロジェクト群。STE はその共有 TOML 基盤。
- 関連: [[Sill-1]]

## 退役語

退役した STE 固有の語。見出しは正規名のまま残し、`deprecated::` で退役バージョンを示す。

### __line__
deprecated:: 2.0.0
退役した合成 dict キー（旧称 `lineKey`）。AoT 行に警告帰属の行番号を埋めていたが、user
キーを shadow し得る・行を iterate するたび skip 必須の leaky abstraction だった。
2.0.0 で [[Row]] ＋ [[SourceSpan]]（型付き位置）に置換。
- コード: Span.swift
- 関連: [[Row]] [[SourceSpan]]

### line-based strict scanner
deprecated:: 3.0.0
退役した旧 strict parse の行ベース scanner。v3.0.0 で `parse` が [[parseWithSpans]] に
委譲し（lossless DOM からの導出に一本化）撤去された。CRLF 正しさや triple-quote 拒否など
tiler の strictness をそのまま契約として引き継いだ。
- コード: ParseWithSpans.swift
- 関連: [[parseWithSpans]] [[parse]]
