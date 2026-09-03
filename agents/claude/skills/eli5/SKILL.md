---
name: eli5
description: 「/eli5 <topic>」と入力されたとき、「絵で説明して」「５歳児向けに説明して」「図解して」「どういう仕組みか教えて」と頼まれたとき、仕組み・不具合・設計を何も知らない人に説明する必要があるときに使う。
---

# eli5

その話題を**何も知らない人**に向けて、大きな絵と少ない言葉で説明する HTML を書く。

書くのは **body フラグメント**。`<!doctype>` も `<html>` も `<head>` も `<body>` も書かない。
外枠（doctype・言語・フォント・スタイルシート・一覧へ戻る線）は
`~/www/eli5/tools/archive.py` が被せる。

デザインは `~/www/eli5/eli5.css` にある。**記事ごとに違ってよいのは、絵と文だけ。**
`<style>` を書いてよいのは自分の絵を動かす / 塗るときだけで、パレット・書体・`e-` の
見た目は上書きしない。

## 書くもの

```html
<title>組織を選ぶ引換券</title>
<meta name="description" content="複数の組織に属するユーザーのログインで、組織を選ぶ前にセッションを渡さず、1 回きり・5 分で失効する引換券を挟む設計">

<div class="e-page">
  <header class="e-head">
    <div>
      <p class="e-eyebrow">SESSION</p>
      <h1>組織を選ぶ<br>引換券</h1>
      <p class="e-lede">鍵をすぐ渡すと、まだ決まっていないことまで決まってしまう。</p>
    </div>
    <div class="e-head-art"><svg …></svg></div>
  </header>

  <div class="e-steps">
    <section class="e-step">
      <div class="e-step-head">
        <span class="e-num">01</span>
        <h2>所属が 1 つなら、迷わない</h2>
      </div>
      <div class="e-two">
        <div><p>…</p></div>
        <figure class="e-fig"><svg …></svg><figcaption>…</figcaption></figure>
      </div>
    </section>
  </div>

  <section class="e-close">
    <h2>ひとことで言うと</h2>
    <p>…</p>
  </section>
</div>
```

`<title>` はたとえ（「ロッカーの鍵とりちがえ事件」）でいい。それが持ち味。
`<meta name="description">` は**具体語で書く**。一覧に出るのはこちらで、たとえのままだと
何の話か分からない。どちらか欠けると保存が失敗する。

## 語彙

`eli5.css` が正。ここは要約。

| クラス | 使いどころ |
|---|---|
| `e-page` | 全体を包む |
| `e-head` / `e-eyebrow` / `e-lede` / `e-head-art` | 冒頭。`e-head-art` を付けると広い画面で見出しの横に絵が並ぶ |
| `e-steps` > `e-step` | 番号付きの節。**6〜10 個**が目安 |
| `e-step--bad` / `e-step--good` | 不具合を見せる節 / 直した節。枠の色が変わる |
| `e-step-head` > `e-num` + `h2` + `e-chip` | 節の見出し。`e-num` は `01` 形式 |
| `e-chip--problem` / `e-chip--fix` | 見出し脇の小さなラベル |
| `e-two` | 中で 2 つ並べると、広い画面で文と絵が左右に並ぶ |
| `e-fig` > `svg` + `figcaption` | 絵。キャプションは必ず付ける |
| `e-fig--panel` | 線の細い図に下地を敷く。表やグラフを入れるときもこれ |
| `e-map` > `table` | 「たとえ → ほんとう」の対応表。右列は自動で等幅・アクセント色になる |
| `e-bars` > `e-bar` | 計測値。`e-bar-track` > `e-bar-fill`（幅は `style="width:42%"`）、`e-bar-num`。遅い方は `e-bar--slow` |
| `e-note` | 短い補足。左に線が入る |
| `e-tally` | 数個の「ラベル + 値」を横に並べる。`dl > div > dt + dd`（`dd` の中に `small` で注釈） |
| `e-close` / `e-foot` | 最後の「ひとことで言うと」／ 補足 |
| `e-bad` / `e-good` / `e-say` | 文中の「壊れている方」「直った方」「短い引用」 |

## 絵

**これが本体。** 文章を削って絵を増やす方向に倒す。1 本あたり 4〜8 枚、inline SVG。

- 色はトークンで塗る: `var(--e-ink)` `var(--e-ink-soft)` `var(--e-line)` `var(--e-surface)`
  `var(--e-accent)`（正しい方）`var(--e-warn)`（壊れている方）`var(--e-mark)`（注目）。
  **リテラルの色で塗った絵はダークモードで消える**
- `viewBox` を付けて `width` / `height` は付けない（`e-fig` が幅を管理する）
- 図が意味を運ぶので `aria-label` を付ける
- 動かすなら `@media (prefers-reduced-motion: no-preference)` の中だけ

## 言葉

- 5 歳児に向けて話す。専門語をたとえに置き換え、最後の `e-map` で対応を明かす
- 1 つの節で 1 つのことだけ言う
- 数字は測った値だけ書く

## private リポジトリの話を書くとき

**repo 名・issue / PR 番号・クラス名・エンドポイント名・cookie 名を書かない。**
保存先の `wadakatu/eli5` は public。役割で書けば説明は成立する。

- ❌ `<private repo 名> · issue #NNNN` / `<内部クラス名>` / `<内部ストア名>`
- ⭕️ `API サーバ` / `セッション Cookie を付けないレスポンス` / `プロジェクトの状態を持つストア`

`e-map` の右列も一般名詞で書く。保存時の検査は教えていない識別子を素通しするので、
書かないことだけが防御になる。

Topic: $ARGUMENTS
