# Re:VIEW BibLaTeX 拡張サンプル

このリポジトリは、Re:VIEW プロジェクトに `review-ext.rb` を置いて BibLaTeX/CSL 参照機能を追加するためのサンプルです。
Re:VIEW 本体を変更せず、プロジェクトローカルの拡張として `@<bibref>`、`@<bibtitle>`、`//biblist` を試せます。

文献データはすべて架空のサンプルです。英語文献と日本語文献、単著と共著、単訳者と複数訳者、`article`、`book`、`incollection`、`inproceedings`、`report`、`thesis` を含めています。

## 必要なもの

- Re:VIEW のチェックアウト
- Pandoc

`review-compile` と `pandoc` を実行できる状態にしてください。

## HTML を生成する

このディレクトリで次のコマンドを実行します。

```sh
review-compile --target html --directory .
```

生成結果は、このディレクトリの `ch01.html`、`ch02.html`、`refs.html` に出力されます。

## LaTeX を生成する

```sh
review-compile --target latex --directory .
```

生成結果は、このディレクトリの `ch01.tex`、`ch02.tex`、`refs.tex` に出力されます。

## サンプルの構成

- `ch01.re`: 基本的な文献参照のサンプルです。単著・複数著者の末尾引用と文中引用を含み、章単位の `//biblist[ch01]` を出力します。
- `ch02.re`: `ch01.re` と重複する文献、別の文献、翻訳書を参照します。`@<bibtitle>` による書名の取り出しも含み、章単位の `//biblist[ch02]` を出力します。
- `refs.re`: `POSTDEF` として登録される、全体の参考文献一覧です。`//biblist` だけを書くと、全体で参照された文献を出力します。

`ch01` や `ch02` は `.re` ファイル名から決まる Re:VIEW の ID です。表示上の章番号ではありません。

## 文献参照の書き方

末尾引用は Pandoc に合わせて、角括弧つきで書きます。

```review
@<bibref>{[@brown2022]}
@<bibref>{[@smith2020, p. 10]}
```

文中引用は `@key` から始めます。

```review
@<bibref>{@brown2022}
@<bibref>{@smith2020 [pp. 20-22]}
```

ページなどの locator の書き方は、末尾引用と文中引用で異なります。

- `@<bibref>{[@smith2020, pp. 20-22]}`: 末尾引用です。ページ指定は引用の中に入ります。
- `@<bibref>{@smith2020 [pp. 20-22]}`: 文中引用です。ページ指定は引用の中に入ります。
- `@<bibref>{@smith2020, pp. 20-22}`: locator ではありません。`@smith2020` の引用のあとに、`, pp. 20-22` という通常の本文が続く扱いになります。

文中引用の `@key [pp. 20-22]` にある `[...]` は Re:VIEW のオプションではなく、`@<bibref>{...}` の中に渡す Pandoc citation の一部です。

複数の文献をまとめて参照する場合も Pandoc の引用記法に合わせます。

```review
@<bibref>{[@brown2022; @smith2020, p. 10]}
```

出力の具体的な表記は CSL に委ねます。たとえば author-date 系の CSL では `(Brown, 2022)` のようになり、numeric 系の CSL では `[1]` のようになります。

## 参考文献一覧

章単位の参考文献一覧は、ID を指定して出力します。

```review
//biblist[ch01]
```

全体の参考文献一覧は、引数なしで出力します。

```review
//biblist
```

## 書名だけを取り出す

翻訳書などで、本文中に書名だけを出したい場合は `@<bibtitle>` を使います。

```review
@<bibtitle>{@translation2020ja}
@<bibtitle>{@translation2020ja,orig}
@<bibtitle>{@translation2020ja,both}
```

それぞれ、翻訳後の書名、原書名、両方を出力します。

## 翻訳書の BibLaTeX

翻訳書は BibLaTeX の標準フィールドで書きます。独自フィールドは使いません。

```biblatex
@book{translation2020ja,
  author        = {Harper, Lio},
  title         = {翻訳された架空の都市論},
  translator    = {藤田, 翼},
  publisher     = {見本翻訳社},
  date          = {2020},
  origtitle     = {Imaginary Cities and Shared Maps},
  origdate      = {2016},
  origpublisher = {Fictional Cartography Press},
  langid        = {japanese}
}
```

`title` は翻訳後の書名、`translator` は訳者、`origtitle` は原書名です。原書の刊行年や出版社が必要な場合は、`origdate` と `origpublisher` を使います。`langid = {japanese}` は、日本語文献として書名を『...』で出すために使います。

## 設定

`config.yml` には、BibLaTeX/CSL の設定例を入れています。

```yaml
biblatex:
  files:
    - references.bib
  style: review.csl
```

`files` には読み込む BibLaTeX ファイルを指定します。`style` には、このプロジェクトから見た CSL ファイルのパスを書きます。

このサンプルでは `style.css` も `config.yml` で指定しています。

別の BibLaTeX ファイルや CSL ファイルを使う場合は、Re:VIEW の設定ファイルに次のように書きます。

```yaml
biblatex:
  files:
    - my-references.bib
  style: my-style.csl
```

`biblatex` 設定を省略した場合でも、`review-ext.rb` はデフォルトで `references.bib` と `review.csl` を使います。

## 主なファイル

- `review-ext.rb`: Re:VIEW プロジェクトローカルの拡張です。`@<bibref>`、`@<bibtitle>`、`//biblist` を実装しています。
- `review.csl`: デフォルトで使う CSL です。
- `references.bib`: 架空の BibLaTeX サンプルデータです。
- `catalog.yml`: `ch01.re`、`ch02.re`、`refs.re` の構成を定義します。
- `config.yml`: Re:VIEW と BibLaTeX/CSL の設定例です。
- `style.css`: HTML 表示用の簡単なスタイルです。
