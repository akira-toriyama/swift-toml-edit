# swift-toml-edit — glossary.md 設計 (t-ncea)

## 目的

家族ルール「開発する repo に用語集 `glossary.md` が無ければ作る。目的＝ユーザーと
Claude Code の認識ズレ防止」に対し、STE だけ未整備。t-jx57（#23）で lens/orphan の
語彙ズレが fixture を嘘つきにしかけた実例があり、foundational library ほど用語正典の
価値が高い。

## 決定事項（brainstorm で確定）

- **リッチ度 = 中**: frontmatter + 短い 2 層アーキ枠組み + 用語ごとの `###` エントリ
  （定義・コード所在・`[[wikilink]]`・退役語は 🪦）。**mermaid アーキ図は作らない**
  （STE はアプリでなくライブラリなので facet ほどの構造は過剰）。
- **Pages 公開を同 PR に含める**: `.github/workflows/glossary.yml` を追加し
  `https://akira-toriyama.github.io/swift-toml-edit/` に公開。
- **スコープ = STE 固有語のみ**。facet 製品語彙（`isolate desktop` 等）は複製せず、
  導入でポインタ 1 本（facet の `docs/glossary.md` が既に `lens`→`isolate` の正典）。

## 配置とフォーマット

- ファイル: `docs/glossary.md`（facet/chord/wand/perch と同じ。STE の `docs/` には
  既に `commit-convention.md` がある）。
- glossary-site tooling の期待に合わせる（Obsidian フレンドリー: YAML frontmatter +
  `[[wikilink]]`。mermaid は build で SVG 化されるが今回は使わない）。
- frontmatter:
  ```yaml
  ---
  title: swift-toml-edit 用語集
  tags: [glossary, swift, toml]
  repo: swift-toml-edit
  aliases: []
  ---
  ```

## ドキュメント構成（4 セクション）

1. **導入** — ユビキタス言語の枠組み（「ここに載る名前だけを使う」）＋ facet 製品語彙は
   facet の正典（https://github.com/akira-toriyama/facet/blob/main/docs/glossary.md）へ
   ポインタ、を 1 段落。正規名は英語のまま（コード識別子と一対一）、説明は日本語。
2. **2 層アーキテクチャ** — 2〜3 文の枠組み（lossless `Annotated` DOM ↔ lossy `Toml`
   projection）＋各 `Sources/Toml/*.swift` の一行役割リスト。mermaid 無し。
3. **コア用語** — `###` エントリ群（下記の用語セット）。
4. **退役語（🪦）** — STE 固有の退役語。

### `###` エントリの形式（facet 準拠・軽め）

```
### trivia
block に付随する raw な空白・コメント。leading / trailing に分かれ、render で
1 バイト単位に復元される（round-trip byte-identity の担い手）。
- コード: Annotated.swift, AnnotatedParse.swift
- 関連: [[trivia attribution]] [[format-preserving]]
```

**アンカーはファイル名のみ**（`file:line` にしない — 行番号は編集で腐る）。

### 見出しと wikilink 解決（glossary-site builder の契約に従う）

builder（`glossary-site/packages/builder/src/build.ts`）の実装を確認した結果、
**`[[wikilink]]` は見出しの正規名テキスト（`###` 行そのまま）と alias に対して解決**
される（`slug()` ではない）。したがって:

- **見出し = クリーンな英語正規名のみ**（`### orphan` / `### trivia attribution` /
  `### format-preserving`）。日本語の但し書きは**本文の 1 行目**に置く。見出しに
  `（TOML 一般語）` のような括弧を入れると term テキストが汚れて `[[orphan]]` が
  解決しなくなる（facet が retired 見出しに 🪦 を入れているのはこの点で不利）。
- `[[wikilink]]` の綴りは**見出しの正規名と完全一致**させる（`[[trivia attribution]]`、
  `[[orphan]]`）。表示名を変えたい場合は `[[正規名|表示名]]`。
- **アンカーはファイル名のみ**（`file:line` にしない — 行番号は編集で腐る）。
- builder は `since:: <v>` / `deprecated:: <v|reason>` / `related:: [[..]]` の
  dataview 風メタも解釈するが、本 glossary では**素の `[[wikilink]]` を本文/関連
  bullet に置く**方針（GitHub raw でも読める facet 流）。retired 語だけ `deprecated::`
  を使う（下記）。

## 用語セット（約 22 語・6 群）

各用語の見出しは**クリーンな英語正規名のみ**（`### orphan`・`### trivia attribution`）。
日本語の但し書きは本文 1 行目へ。`[[wikilink]]` はその正規名テキストと**完全一致**で
綴る（builder は term/alias テキストで解決するため。上の「見出しと wikilink 解決」節）。

### 群 1: 不変条件
- **format-preserving** — 何を parse できれば round-trip できる、の原則
- **byte-identity** — 変えない block は read→write で 1 バイト同一
- **full format-preservation** — parse 可能なものは round-trip 可能（lenient skip は
  lossy projection 層でのみ再現）
- **trivia** — leading/trailing の raw 空白・コメント
- **trivia attribution** — コメント/空行は直後の header block に付く（wand#129 ルール）

### 群 2: 2 層モデル
- **lossless Annotated DOM** — value 型・Sendable、各 node が raw spelling + trivia を持つ
- **lossy projection** — sill の `Toml` と同名の read API を再露出する層
- **block** / **entry** / **body（leading・trailing）** — DOM の構造単位

### 群 3: 読みの 3 スキン
- **parse**（nested・strict、chord 経路。v3 で `parseWithSpans` に委譲）
- **parseFlat**（flat・lenient、facet/perch/wand。line scanner のまま）
- **parseWithSpans**（span つき strict engine → `SpannedTree`）
- **SpannedTree** / **EntrySpans** / **PathSegment** — 行+列スパン付きツリー
- **Row** — AoT 行（fields + `[[header]]` の `SourceSpan`）
- **SourceSpan** — 警告帰属の型付き位置（合成 dict キーの後継）

### 群 4: 字句・構造
- **tiler** — 物理行を分類し lossless block へ畳む scanner
- **lexLines** — scalar ベースの物理行分割（CRLF 正しさの根・t-b9ws）
- **lexValueText** — comment 除去・trim 済みの値テキスト抽出
- **M1 / M2** — マイルストン（M1 = 行ベース tiler、M2 = multi-line string + strict decode）
- **AoT（array-of-tables）** — `[[a.b]]` ブロック
- **orphan（TOML 一般語）** — AoT 親の削除で取り残される `[path.sub]`。**facet が撤去した
  製品語彙の orphan とは別物**（機械的 rename で回帰させかけた実例あり・t-jx57）と明記。厚めに書く。

### 群 5: 厳格 decode / encode（toml-test 経路）
- **Toml.Value（lossy・凍結）** vs **TypedValue（strict）** — 2 つの値モデルの対比
- **redefinition state machine** — TOML 1.0 の table/key 再定義セマンティクス（TypedTree）
- **conformance / toml-test** — v1.0 カバレッジのバー
- **tagged-JSON** — toml-test のワイヤ形式

### 群 6: 編集と位置づけ
- **edit ops** — `settingValue`/`upsertingValue`/`settingArrayValue`/`reorderingArrayOfTables`/
  `removing…`。functional（新 document を返す・値意味論）、minimal（YAGNI）
- **golden / fixture** — 家族の実 config を vendor した回帰検知素材（drift は t-hefq）
- **Sill-1 / atelier family** — この repo の位置づけ（sill の lossy `Toml` を置換）

## 退役語（deprecated）

STE 固有のもののみ（facet の `lens` 等は複製しない）。見出しはクリーンな正規名にし、
builder の `deprecated:: <version>` メタで退役を示す（🪦 は見出しに入れない ＝ term
テキストを汚さず `[[wikilink]]` が解決する）:

- **`__line__`** — 2.0.0 で `Row` + `SourceSpan` に置換。user キーを shadow し得る・
  iterate 時に skip 必須だった leaky abstraction。（`lineKey` は本文で言及）
  ```
  ### __line__
  deprecated:: 2.0.0
  合成 dict キー（旧称 `lineKey`）。AoT 行に警告帰属の行番号を埋めていたが …
  → [[Row]] + [[SourceSpan]] に置換。
  ```
- **line-based strict scanner** — v3.0.0 で `parse` が `parseWithSpans` に委譲し撤去。
  ```
  ### line-based strict scanner
  deprecated:: 3.0.0
  旧 strict parse の行ベース scanner。v3 で [[parseWithSpans]] 委譲により撤去 …
  ```

## 規約（glossary 末尾に明記）

- facet 製品語彙は**複製せず**導入のポインタ 1 本で参照。
- `[[wikilink]]` で相互リンク（slug = 見出しの kebab-case）。
- 用語の追加・改名はコード変更と**同一 PR**（家族ルール）。

## `glossary.yml`（Pages 公開）

facet の `.github/workflows/glossary.yml`（約 30 行）を複製:
- トリガ: `push`（`docs/glossary.md` / `.github/workflows/glossary.yml` の paths）+
  `pull_request`（build のみ）+ `workflow_dispatch`。
- `uses: akira-toriyama/glossary-site/.github/workflows/deploy.yml@main`。
- permissions: `contents: read` / `pages: write` / `id-token: write`。
- concurrency: `pages-${{ github.event.number || github.ref }}`。
- **zizmor 対応**: STE の CI は zizmor low ゲートを持つので、reusable 呼び出しに余計な
  権限や pinned でない外部 action を足さない（deploy.yml 側が実体なので、caller は薄い）。

## テスト / 検証

glossary.md 自体は散文なので機械検証は薄いが、**builder を `--strict` で回すのが正典の
lint**（dangling wikilink を exit 3 で落とす）。glossary-site は clone 済み・Node v24。

```sh
cd /Volumes/workspace/github.com/akira-toriyama/glossary-site
pnpm install    # 初回のみ（gray-matter 等の dep を入れる）
node packages/builder/bin/glossary-build.mjs \
  --input /Volumes/workspace/github.com/akira-toriyama/swift-toml-edit/docs/glossary.md \
  --output /tmp/ste-glossary.json \
  --repo swift-toml-edit --strict
```

- 期待: **exit 0**、`wrote: …` と `entries: N, diagrams: 0, …`、`broken wikilinks` 行なし。
- dangling があると builder が `broken wikilinks (K):` を列挙、`--strict` で **exit 3**。
  出たら綴りを見出し正規名に合わせて直す（builder は term/alias テキストで解決）。
- mermaid は使わない（`diagrams: 0`）ので mermaid-cli の重い経路は踏まない。
- frontmatter が有効な YAML であることは builder が parse 成功することで担保される
  （不正なら gray-matter が throw → exit 1）。
- taplo は fixture を除外しているが glossary.md は TOML ではないので無関係。

workflow は PR の `pull_request` トリガで build ジョブが緑になることで検証（deploy はしない）。

## スコープ外（YAGNI）

- mermaid アーキ図（中リッチの選択で除外）。
- facet 製品語彙の定義（ポインタのみ）。
- 横断ビュー（glossary-site は repo 単位）。
- glossary の内容を機械アサートする test（散文なので過剰）。

## 関連タスク

- t-ncea（本タスク）
- t-jx57（#23・lens→isolate 語彙追随の実績。glossary の運用先ができる）
- t-hefq（fixture drift・golden/fixture 用語から参照）
- t-fyq6（CLAUDE.md の swap 記述 stale・同じ doc 整備なので相乗り可）
