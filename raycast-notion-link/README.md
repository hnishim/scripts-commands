# Notion Link（Raycast）

NotionページのURLをクリップボードへコピーしてから、Raycastの「Paste Notion Link」または「Copy Notion Link」を実行します。前者は前面アプリへタイトル付きリンクを貼り付け、後者はクリップボードへコピーします。リッチテキスト向けHTMLリンクと、プレーンテキスト向けMarkdownリンクを同時に渡します。

## ローカル導入

1. Raycastの拡張機能開発環境でこのディレクトリに移動し、`npm install`、`npm run dev` を実行して拡張を読み込みます。
2. Raycast拡張機能の設定で `Notion Integration Token` を登録し、対象NotionページをそのIntegrationへ共有します。トークンをコード・リポジトリへ保存しないでください。
3. 必要に応じてRaycastの設定から各コマンドにホットキーを割り当てます。

## 検証

- `npm test`：URL、Notion API、エラー処理、認証別キャッシュと出力形式の自動テスト（認証・GUI不要）
- `npm run lint` と `npm run build`：拡張機能の静的検査とビルド
- 実機受入：SlackのComposerと送信後のリンク、リッチテキスト入力先、Markdownエディタ、実Notionの権限、Paste・Copy両コマンドを確認します。

実MacのRaycast・Notion認証・各貼り付け先の動作はソースの自動テストだけでは確認できません。
