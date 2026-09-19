# Notion textlint コマンド

## 目的・実行方法

指定したNotionページのMarkdownを取得し、dotfiles側の既存textlint設定で自動修正し、変更箇所だけをNotionへ書き戻します。ページを自動検出する機能は含みません。URLまたはページIDを明示的に指定します。

```bash
python3 notion-textlint.py 'https://www.notion.so/<対象ページURL>'
# または
python3 notion-textlint.py '<ページID>'
```

通常のローカル配置は `Dev/scripts/commands/notion-textlint.py` で、同じ `Dev` 配下に `dotfiles/textlint/.textlintrc.json` がある前提です。移行元の `dotfiles/textlint/notion-textlint.py` は使いません。CLIは既存の `hnishim/scripts-raycast` リポジトリで管理し、リポジトリ名は変更しません。

## 必要な実行環境

- `ntn` がコマンド探索パスに存在し、対象ページにアクセスできるNotion認証が完了していること。
- `dotfiles/textlint/textlint-setup.sh` によって `$HOME/Library/Application Support/dotfiles/textlint/node_modules/.bin/textlint` が構築されていること。
- 設定の正本 `dotfiles/textlint/.textlintrc.json` と、その `prh.rulePaths` が参照する `$HOME/my-prh.yml` が正しい現行の辞書を指すこと。設定・辞書・認証情報は本リポジトリへコピーしません。

隣接するdotfilesがない独立checkoutでは、同じ設定の実ファイルを環境変数 `NOTION_TEXTLINT_CONFIG` で明示的に指定できます。変数が指定された場合、別の設定へ暗黙に切り替えません。

```bash
NOTION_TEXTLINT_CONFIG="$HOME/path/to/dotfiles/textlint/.textlintrc.json" \
  python3 notion-textlint.py '<ページID>'
```

設定・実行環境・認証のいずれかが利用不能な場合は、CLIがエラーとして終了します。自動検出・常時監視・Raycast固有のメタデータ追加はHIR-280の対象外です。

## 変更の安全性と確認

CLIは変更前にページを再取得し、初回取得時と内容が異なる場合は書き込みません。差分は一意に特定した箇所へ `update_content` で適用し、全文置換は行いません。更新後にMarkdownを再取得し、期待値に一致しなければエラーを報告し、追加書き込みはしません。自動修正できないtextlint指摘が残る場合も、有効な修正だけを反映します。

ローカル受入確認では専用の安全なNotionページを使用してください。実際の `scripts/commands` 配置で、dotfiles設定と `~/my-prh.yml` のリンク先、Application Supportのtextlint、`ntn` の認証が正しいことを確認します。修正可能な箇所と未修正指摘を共存させ、対象限定の更新が一度行われて更新後取得が一致すること、変更がない場合は書き込まないことを確認します。実APIの競合・権限・未対応ブロックの扱いは、模擬テストだけでは検証できません。

## 自動テスト

```bash
python3 -m unittest discover -s tests -p 'test_notion_textlint*.py'
bash tests/ci_test.sh
```

テストは模擬 `ntn`・模擬textlint・一時HOMEを使用するため、実Notionページや実Macの認証を検証しません。dotfilesの実行環境構築・辞書リンクのテストは引き続きdotfiles側で管理します。
