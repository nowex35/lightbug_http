# MCP 実装ギャップ分析
**Model Context Protocol 2025-03-26 仕様準拠状況**

作成日: 2025-10-06

---

## エグゼクティブサマリー

本ドキュメントは、lightbug_httpプロジェクトにおける現在のMCP実装のギャップを包括的に分析し、**プロトコルレベルのHTTPトランスポート要件**と**高レベルのMCP機能**の両方をカバーします。

**全体的な完成度: 約55-60%**

### 致命的なギャップ
- ❌ HTTP OPTIONSメソッド (CORSプリフライト) - **すべてのブラウザクライアントをブロック**
- ❌ HTTP GET + Last-Event-ID (SSE再接続機能) - **接続復旧不可**
- ❌ Resourcesフィーチャー - **MCPのコア機能が欠落**
- ❌ Promptsフィーチャー - **MCPのコア機能が欠落**

---

## Part 1: HTTPプロトコル層のギャップ

### 🔴 P0 - 致命的なプロトコル問題

#### 1.1 HTTP OPTIONSメソッド対応 (CORSプリフライト)

**仕様要件:**
- ブラウザベースのクライアントは、実際のPOSTリクエストの前にOPTIONSプリフライトリクエストを送信する
- サーバーは適切なCORSヘッダーで応答しなければならない

**現状:**
- ✅ `MCPOptionsHandler`が`transport.mojo:222-240`に存在
- ❌ **ハンドラーがどのサーバーにもマウントされていない**
- ❌ `StreamingTransport`がOPTIONS処理を完全に欠いている
- ❌ `StreamingTransport.call()` (47行目)にOPTIONSルーティングがない

**影響:**
- ブラウザベースのMCPクライアントが接続できない
- WebアプリケーションからMCPを使用できない

**コード位置:**
```
lightbug_http/mcp/streaming_transport.mojo:47-63
lightbug_http/mcp/transport.mojo:222-240
```

**必要な実装:**
```mojo
fn call(mut self, mut exchange: StreamableHTTPExchange) raises:
    if exchange.method == "OPTIONS":
        self._handle_preflight(exchange)
        return
    # ... 既存のロジック
```

---

#### 1.2 SSE再接続機能 (Last-Event-ID)

**MCP 2025-03-26 仕様:**
> "サーバーはSSEイベントに`id`フィールドを付与してもよい(MAY)。クライアントが接続断後に再開したい場合、MCPエンドポイントへHTTP GETを発行し、最後に受信したイベントIDを示す`Last-Event-ID`ヘッダーを含めるべきである(SHOULD)。"

**現状:**
- ✅ SSEイベント送信機能は実装済み (`write_sse_event`)
- ❌ **SSEイベントIDの割り当てがない** - idパラメータは存在するが不完全な実装
- ❌ **HTTP GETエンドポイントが存在しない** - POSTのみサポート
- ❌ **`Last-Event-ID`ヘッダーの処理が皆無**
- ❌ **イベント再生メカニズムが未実装**

**影響:**
- 接続断時の自動復旧ができない
- 長時間稼働するストリーミングセッションで信頼性が低い

**コード位置:**
```
lightbug_http/streaming/streamable_exchange.mojo:374-389
lightbug_http/mcp/streaming_transport.mojo:230-248
```

**必要な実装:**
1. セッションごとのイベント履歴バッファ
2. イベントID生成と追跡
3. Last-Event-IDパース機能を持つHTTP GETエンドポイント
4. イベント再生ロジック

---

#### 1.3 HTTP GETメソッド対応

**MCP仕様要件:**
- クライアント → サーバー: **HTTP POST**
- SSE再接続: **HTTP GET with Last-Event-ID**

**現状:**
```mojo
# streaming_transport.mojo:72
if exchange.method != "POST":
    self._send_error(exchange, 405, "Method not allowed. Use POST")
```

- ❌ **GETメソッドが完全に拒否される**
- ❌ SSE再接続が実装不可能

**影響:**
- 仕様違反
- SSE復旧機能なし

**必要な実装:**
```mojo
if exchange.method == "GET":
    if "Last-Event-ID" in exchange.headers:
        self._handle_sse_resume(exchange)
    else:
        self._handle_sse_endpoint(exchange)
    return
elif exchange.method == "POST":
    # ... 既存のロジック
```

---

### 🟠 P1 - 重要なプロトコル問題

#### 1.4 Acceptヘッダーの検証

**MCP仕様:**
> "クライアントは、`application/json`と`text/event-stream`の両方をサポートされるコンテンツタイプとしてリストしたAcceptヘッダーを含めなければならない(MUST)。"

**現状:**
```mojo
# streaming_transport.mojo:163-168
var accept_header = String("")
try:
    if "Accept" in exchange.headers:
        accept_header = String(exchange.headers["Accept"])
except:
    pass
```

- ⚠️ Acceptヘッダーは読み込まれているが**検証されていない**
- ⚠️ クライアントの能力が適切にネゴシエーションされていない
- ❌ 仕様違反: `application/json`と`text/event-stream`の両方をサポートする必要がある

**必要な実装:**
1. Acceptヘッダーをパース
2. 必須のMIMEタイプ両方の存在を検証
3. 欠落している場合は406 Not Acceptableを返す

---

#### 1.5 Content-Typeレスポンスネゴシエーション

**MCP仕様:**
> "サーバーは`Content-Type: text/event-stream`または`Content-Type: application/json`のいずれかを返さなければならない(MUST)"

**現在の問題:**
```mojo
# streaming_transport.mojo:170-189
var use_sse = False
# コメント: "For now, only use SSE for /sse endpoint..."
# 実際にはuse_sseは常にFalseにハードコードされている
```

- ⚠️ SSE判定ロジックが**Falseにハードコード**されている
- ⚠️ Acceptヘッダーを読んでも活用していない
- ❌ 仕様要件を満たせない: "複数のJSON-RPCリクエストが含まれる場合はSSEを使用"

**必要な実装:**
1. リクエストをパースして複数のJSON-RPCメッセージを検出
2. 複数のリクエストがある場合はSSEを使用
3. クライアントのAcceptヘッダーの優先順位を尊重

---

#### 1.6 SSEイベントIDの割り当て

**現状:**
```mojo
fn write_sse_event(mut self, event_type: String, data: String, id: String = "") raises:
```

- ✅ `id`パラメータは存在
- ❌ **実際には使用されていない**
- ❌ ID生成戦略がない

**必要な実装:**
1. セッションごとのグローバルイベントIDカウンター
2. 提供されない場合の自動ID割り当て
3. フォーマット: `id: {session_id}-{sequence_number}\n`

**コード位置:**
```
lightbug_http/streaming/streamable_exchange.mojo:374-389
lightbug_http/streaming/streamable_body_stream.mojo:140-152
```

---

### 🟡 P2 - 拡張プロトコル問題

#### 1.7 SSEセッション管理 & Keep-Alive

**現在の問題:**
```mojo
# streaming_transport.mojo:230-248
fn _handle_sse_endpoint(mut self, mut exchange: StreamableHTTPExchange):
    exchange.start_sse_stream()
    exchange.write_sse_event("connect", "...")
    exchange.write_sse_event("ready", "...")
    # 接続が即座に終了してしまう
```

- ❌ SSEストリームが開始されるがすぐに終了
- ❌ **Keep-Aliveメカニズムがない**
- ❌ **ハートビート/ping送信がない**
- ❌ 長時間セッションを維持できない

**必要な実装:**
1. アクティブなSSE接続のセッションレジストリ
2. 定期的なハートビート（15-30秒ごとのコメント行）
3. 接続ライフサイクル管理
4. セッションタイムアウト時のグレースフルシャットダウン

---

#### 1.8 HTTP/1.1 コネクション永続性

**現状:**
```mojo
# streamable_exchange.mojo:310-312
self.response_headers["Connection"] = "keep-alive"
```

- ✅ SSE用にkeep-aliveヘッダーが設定される
- ❌ **実際のTCP接続永続化ロジックが不明瞭**
- ❌ リクエスト完了後にソケットが閉じられる可能性

**必要な実装:**
1. TCPソケットが開いたままであることを検証
2. コネクションプーリングの実装
3. Connection: closeの適切な処理

---

#### 1.9 複数のJSON-RPCバッチリクエスト

**MCP仕様:**
- 単一リクエスト → JSONレスポンス
- 複数リクエスト → 複数イベントのSSEストリーム

**現状:**
- ❌ **バッチリクエスト検出なし**
- ❌ SSEへの自動切り替えなし

**必要な実装:**
1. リクエストをパースしてJSON-RPC配列を検出
2. バッチが検出されたらSSEモードに切り替え
3. 各レスポンスを個別のSSEイベントとして送信

---

#### 1.10 再生用のイベント履歴バッファ

**Last-Event-IDサポートのため:**

**必要な実装:**
1. 最近のイベントの循環バッファ（例: 最新1000イベント）
2. セッションごとのイベント保存
3. イベントの有効期限（例: 1時間）
4. バッファサイズのメモリ管理

---

## Part 2: MCP機能レベルのギャップ

### 🔴 P0 - コアMCP機能（完全に欠落）

#### 2.1 Resourcesフィーチャー

**MCP仕様:**
Resourcesは、モデルのコンテキストに含めることができるデータを表します:
- データベースレコード
- ファイル内容
- APIレスポンス
- スクリーンキャプチャ
- ログファイル

**必要なメソッド:**
- ❌ `resources/list` - 利用可能なリソースをリスト
- ❌ `resources/read` - リソース内容を読み取り
- ❌ `resources/templates/list` - リソーステンプレートをリスト
- ❌ `resources/templates/read` - テンプレートを読み取り
- ❌ `resources/updated` - リソース変更の通知

**現状:**
```mojo
# server.mojo:914-933
@value
struct ResourcesHandler(RequestHandler):
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        # すべてのメソッドが"not implemented"エラーを返す
        var error = JSONRPCError(-32601, "resources/list method is not currently implemented...")
```

- ✅ ハンドラー構造は存在
- ❌ **すべてのメソッドがエラーレスポンスを返す**
- ❌ 実際のリソース管理がない

**実装要件:**
1. リソースレジストリとストレージ
2. リソース識別のためのURIスキーム
3. MIMEタイプの処理
4. リソースメタデータ（名前、説明、URI）
5. 動的リソースのテンプレートサポート
6. 変更通知システム

**優先度:** 致命的 - ResourcesはMCPのコアプリミティブ

---

#### 2.2 Promptsフィーチャー

**MCP仕様:**
Promptsは、モデルが特定のツールやリソースとどのように対話するかをガイドするテンプレートです。

**必要なメソッド:**
- ❌ `prompts/list` - 利用可能なプロンプトをリスト
- ❌ `prompts/get` - 引数付きで特定のプロンプトを取得
- ❌ `prompts/updated` - プロンプト変更の通知

**現状:**
```mojo
# server.mojo:936-955
@value
struct PromptsHandler(RequestHandler):
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        # すべてのメソッドが"not implemented"エラーを返す
```

- ✅ ハンドラー構造は存在
- ❌ **すべてのメソッドがエラーレスポンスを返す**
- ❌ プロンプト管理がない

**実装要件:**
1. プロンプトレジストリ
2. テンプレート変数の置換
3. プロンプトメタデータ（名前、説明、引数）
4. 引数の検証
5. 変更通知システム

**優先度:** 致命的 - PromptsはMCPのコアプリミティブ

---

### 🟠 P1 - 標準トランスポート

#### 2.3 stdioトランスポート

**MCP仕様:**
stdioは、Streamable HTTPと並ぶ正式に指定された標準トランスポートです。

**現状:**
- ❌ **完全に未実装**
- ✅ HTTPトランスポートのみ

**影響:**
- ローカル/デスクトップMCPクライアントをサポートできない
- ネットワークベースの通信に制限される

**実装要件:**
1. stdinからJSON-RPCを読み込む
2. stdoutにレスポンスを書き込む
3. stderrにエラー/ログメッセージ
4. 適切なバッファリングと改行処理

**優先度:** 中 - 多くのMCPクライアントがstdioを使用

---

### 🟡 P2 - 高度な機能

#### 2.4 Samplingフィーチャー

**MCP仕様:**
サーバーがクライアントにLLMサンプリングを要求できるようにします。

**必要なメソッド:**
- ❌ `sampling/createMessage` - LLMにメッセージ生成を要求

**現状:**
```mojo
# messages.mojo:46-56
struct MCPCapabilities:
    var sampling: Bool
```

- ✅ 能力フィールドは存在
- ❌ **ハンドラー実装がない**
- ❌ サンプリングリクエスト/レスポンスロジックがない

**実装要件:**
1. サンプリングリクエストビルダー
2. モデルパラメータサポート（temperature, max_tokensなど）
3. メッセージフォーマット処理
4. レスポンス処理

**優先度:** 低 - オプション機能、AI駆動サーバーに有用

---

#### 2.5 Rootsフィーチャー

**MCP仕様:**
クライアントがサーバーアクセス制御のためにファイルシステムルートを公開できるようにします。

**必要なメソッド:**
- ❌ `roots/list` - 利用可能なルートディレクトリをリスト
- ❌ ルート変更通知

**現状:**
```mojo
# messages.mojo:46-56
struct MCPCapabilities:
    var roots: Bool
```

- ✅ 能力フィールドは存在
- ❌ **ハンドラー実装がない**

**実装要件:**
1. ルートディレクトリレジストリ
2. パス検証とセキュリティ
3. 変更通知システム

**優先度:** 低 - 主にファイルシステムアクセス制御用

---

## Part 3: 実装の強み

### ✅ よく実装されている機能

#### 3.1 JSON-RPC 2.0 基盤
**ステータス:** ✅ 完成 (100%)

**ファイル:**
- `lightbug_http/mcp/jsonrpc.mojo`
- `lightbug_http/mcp/parser.mojo`

**機能:**
- ✅ Request/Response/Notification型
- ✅ 標準エラーコード
- ✅ メッセージ検証
- ✅ Python JSON統合パーサー
- ✅ シリアライゼーション

---

#### 3.2 ライフサイクル管理
**ステータス:** ✅ 完成 (100%)

**ファイル:**
- `lightbug_http/mcp/server.mojo:285-425`
- `lightbug_http/mcp/messages.mojo:93-113`

**機能:**
- ✅ Initialize/Initializedフロー
- ✅ 接続状態管理 (CONNECTING → INITIALIZING → READY)
- ✅ 能力ネゴシエーション
- ✅ プロトコルバージョン検証 (2025-06-18)

---

#### 3.3 Toolsシステム
**ステータス:** ✅ 完成 (100%)

**ファイル:**
- `lightbug_http/mcp/tools.mojo`
- `lightbug_http/mcp/server.mojo:401-444`

**機能:**
- ✅ `tools/list` - ツール列挙
- ✅ `tools/call` - ツール実行
- ✅ JSON Schemaパラメータ検証
- ✅ 型安全なパラメータ処理 (string, number, boolean, enum)
- ✅ ツールレジストリとエグゼキュータパターン
- ✅ 安全性チェック（並行実行制限、タイムアウト）
- ✅ 詳細なエラーメッセージを含む検証

**ハイライト:**
- 高度なパラメータ検証システム
- 並行実行制限
- 適切なエラー処理

---

#### 3.4 セッション管理
**ステータス:** ✅ 完成 (100%)

**ファイル:**
- `lightbug_http/mcp/session.mojo`

**機能:**
- ✅ セッションID生成 (UUID v4)
- ✅ セッション状態追跡
- ✅ タイムアウト管理（デフォルト30分）
- ✅ 自動クリーンアップ
- ✅ アクティビティ追跡
- ✅ 接続-セッションマッピング

**ハイライト:**
- 高度なタイムアウト処理でMCP標準を超える

---

#### 3.5 タイムアウト & キャンセレーション
**ステータス:** ✅ 完成 (100%)

**ファイル:**
- `lightbug_http/mcp/timeout.mojo`
- `lightbug_http/mcp/server.mojo:665-749`

**機能:**
- ✅ リクエストタイムアウト監視
- ✅ プログレス通知
- ✅ キャンセレーション通知
- ✅ 設定可能なタイムアウトポリシー
- ✅ タイムアウト統計

---

#### 3.6 HTTPトランスポート（基本）
**ステータス:** ✅ ほぼ完成 (80%)

**ファイル:**
- `lightbug_http/mcp/transport.mojo`
- `lightbug_http/mcp/streaming_transport.mojo`

**機能:**
- ✅ クライアント-サーバー間のHTTP POST
- ✅ Content-Type検証
- ✅ CORSヘッダー
- ✅ Origin検証
- ✅ Mcp-Session-Idヘッダー経由のセッションID
- ✅ チャンク転送エンコーディングサポート
- ✅ SSEイベント書き込みプリミティブ

**ギャップ:** Part 1を参照

---

#### 3.7 ロギング
**ステータス:** ✅ 完成 (100%)

**ファイル:**
- `lightbug_http/mcp/jsonrpc.mojo:221-230`

**機能:**
- ✅ stderr出力（MCP準拠）
- ✅ コンテキスト付きエラーロギング
- ✅ Python sys.stderr統合

---

## Part 4: 優先順位付き実装ロードマップ

### フェーズ1: 致命的なHTTPプロトコル修正 (P0)
**推定工数:** 2-3日

#### タスク:
1. **OPTIONSメソッドハンドラー**
   - ファイル: `lightbug_http/mcp/streaming_transport.mojo`
   - `_handle_preflight()`メソッドを追加
   - `call()`でOPTIONSをルーティング
   - ブラウザクライアントでテスト

2. **HTTP GETサポート**
   - GETメソッド処理を追加
   - 基本的なSSEエンドポイントアクセス
   - Last-Event-IDの準備

3. **Last-Event-ID基本サポート**
   - イベントID生成
   - ヘッダーパース
   - シンプルなイベント再生バッファ（メモリ内、最大100イベント）

**成功基準:**
- ✅ ブラウザクライアントが接続可能
- ✅ GET経由でSSE接続を確立可能
- ✅ 基本的な再接続が動作

---

### フェーズ2: コアMCP機能 (P0)
**推定工数:** 5-7日

#### タスク:
1. **Resources実装**
   - リソースレジストリ構造
   - `resources/list`ハンドラー
   - `resources/read`ハンドラー
   - ファイルベースのリソースプロバイダー
   - URIスキームサポート

2. **Prompts実装**
   - プロンプトレジストリ構造
   - `prompts/list`ハンドラー
   - `prompts/get`ハンドラー
   - テンプレート変数置換
   - 引数検証

**成功基準:**
- ✅ リソースの登録とリスト化が可能
- ✅ リソース内容の読み取りが可能
- ✅ プロンプトの登録と実行が可能
- ✅ テンプレート置換が動作

---

### フェーズ3: プロトコル拡張 (P1)
**推定工数:** 3-4日

#### タスク:
1. **Acceptヘッダー検証**
   - Acceptヘッダーのパース
   - 必須のMIMEタイプを検証
   - 適切なエラーを返す

2. **SSEイベントID割り当て**
   - 提供されない場合の自動ID生成
   - セッションベースのIDシーケンス
   - SSEストリームへの書き込み

3. **Content-Typeネゴシエーション**
   - 複数のJSON-RPCリクエストを検出
   - バッチの場合は自動的にSSEに切り替え
   - クライアントの優先順位を尊重

4. **SSEセッションKeep-Alive**
   - ハートビートメカニズム（コメント行）
   - セッションレジストリ
   - グレースフルシャットダウン

**成功基準:**
- ✅ 適切なコンテンツネゴシエーション
- ✅ すべてのSSEイベントにイベントID
- ✅ 長時間のSSE接続が安定

---

### フェーズ4: 標準トランスポート (P1)
**推定工数:** 2-3日

#### タスク:
1. **stdioトランスポート**
   - stdinリーダー
   - stdoutライター
   - エラー用stderr
   - ラインベースプロトコル

**成功基準:**
- ✅ stdio経由で標準MCPクライアントと動作

---

### フェーズ5: 高度な機能 (P2)
**推定工数:** 4-5日

#### タスク:
1. **Samplingフィーチャー**
   - `sampling/createMessage`ハンドラー
   - モデルパラメータサポート
   - レスポンス処理

2. **Rootsフィーチャー**
   - `roots/list`ハンドラー
   - ルートレジストリ
   - パスセキュリティ

3. **イベント履歴バッファ**
   - 永続的なイベントストレージ
   - 設定可能なバッファサイズ
   - 有効期限ポリシー

4. **リソーステンプレート**
   - `resources/templates/list`
   - `resources/templates/read`
   - 動的テンプレート解決

**成功基準:**
- ✅ MCP 2025-03-26完全準拠
- ✅ すべてのオプション機能が実装済み

---

## Part 5: テスト要件

### プロトコルレベルのテスト

#### HTTPトランスポートテスト:
1. ✅ POSTリクエスト処理（存在）
2. ❌ OPTIONSプリフライト（欠落）
3. ❌ Last-Event-ID付きGET（欠落）
4. ❌ Acceptヘッダー検証（欠落）
5. ❌ SSEイベントID割り当て（欠落）
6. ❌ SSE再接続（欠落）

#### SSEテスト:
1. ✅ 基本的なSSEストリーミング（存在）
2. ❌ イベントID生成（欠落）
3. ❌ Last-Event-ID再開（欠落）
4. ❌ ハートビート/keep-alive（欠落）
5. ❌ ストリームごとの複数イベント（欠落）

### 機能レベルのテスト:

#### Resourcesテスト:
1. ❌ リソースリスト
2. ❌ リソース読み取り
3. ❌ テンプレートリスト
4. ❌ テンプレート読み取り
5. ❌ リソース更新

#### Promptsテスト:
1. ❌ プロンプトリスト
2. ❌ 引数付きプロンプト取得
3. ❌ テンプレート置換
4. ❌ プロンプト更新

#### stdioトランスポートテスト:
1. ❌ stdinから読み込み
2. ❌ stdoutに書き込み
3. ❌ stderrにエラー
4. ❌ ラインバッファリング

---

## Part 6: コードアーキテクチャの推奨事項

### 6.1 リファクタリングの必要性

#### トランスポート関心事の分離:
```
lightbug_http/mcp/transports/
├── http_transport.mojo       # 基本的なHTTP POST
├── streaming_transport.mojo  # SSEサポート
├── stdio_transport.mojo      # 標準I/O
└── transport_base.mojo       # 共通インターフェース
```

#### 機能モジュール:
```
lightbug_http/mcp/features/
├── resources/
│   ├── resource.mojo
│   ├── registry.mojo
│   └── handler.mojo
├── prompts/
│   ├── prompt.mojo
│   ├── registry.mojo
│   └── handler.mojo
└── sampling/
    └── handler.mojo
```

### 6.2 設定管理

中央設定を追加:
```mojo
struct MCPServerConfig:
    var enable_resources: Bool
    var enable_prompts: Bool
    var enable_sampling: Bool
    var enable_sse_resume: Bool
    var sse_event_buffer_size: Int
    var sse_heartbeat_interval_ms: Int
    var max_sse_connections: Int
```

---

## Part 7: 準拠性サマリー

### MCP 2025-03-26 仕様準拠

| カテゴリ | 準拠 | 注記 |
|----------|------|------|
| **JSON-RPC 2.0** | ✅ 100% | 完成 |
| **ライフサイクル** | ✅ 100% | 完成 |
| **Tools** | ✅ 100% | 完成 |
| **Resources** | ❌ 0% | 未実装 |
| **Prompts** | ❌ 0% | 未実装 |
| **Sampling** | ❌ 0% | 未実装 |
| **ロギング** | ✅ 100% | 完成 |
| **HTTP POSTトランスポート** | ⚠️ 70% | OPTIONS、GET欠落 |
| **SSEストリーミング** | ⚠️ 60% | 再接続機能欠落 |
| **stdioトランスポート** | ❌ 0% | 未実装 |

### プロトコル要件

| 要件 | ステータス | 優先度 |
|------|-----------|--------|
| リクエスト用HTTP POST | ✅ 完成 | - |
| SSE再開用HTTP GET | ❌ 欠落 | P0 |
| CORS用OPTIONS | ❌ 欠落 | P0 |
| Acceptヘッダー検証 | ⚠️ 部分的 | P1 |
| Content-Typeネゴシエーション | ⚠️ 部分的 | P1 |
| SSEイベントID | ❌ 欠落 | P1 |
| Last-Event-ID処理 | ❌ 欠落 | P0 |
| コネクションkeep-alive | ⚠️ 不明瞭 | P1 |

---

## Part 8: 推定総工数

### 開発工数:
- **フェーズ1 (P0プロトコル):** 2-3日
- **フェーズ2 (P0機能):** 5-7日
- **フェーズ3 (P1プロトコル):** 3-4日
- **フェーズ4 (stdio):** 2-3日
- **フェーズ5 (P2機能):** 4-5日

**合計:** 約16-22日 (3-4週間)

### テスト工数:
- **ユニットテスト:** 5-7日
- **統合テスト:** 3-5日
- **E2Eテスト:** 2-3日

**合計:** 約10-15日 (2-3週間)

### ドキュメント:
- **APIドキュメント:** 2-3日
- **サンプル:** 2-3日
- **移行ガイド:** 1-2日

**合計:** 約5-8日 (1-1.5週間)

---

## 結論

現在の実装には**優れた基盤**があります:
- ✅ 堅牢なJSON-RPCインフラストラクチャ
- ✅ 完全なTools実装
- ✅ 高度なセッション管理
- ✅ 優れたタイムアウト/キャンセレーションシステム

しかし、MCPの完全準拠を妨げる**致命的なギャップ**があります:

### 修正必須 (P0):
1. ❌ OPTIONSメソッド（ブラウザをブロック）
2. ❌ HTTP GET + Last-Event-ID（再接続不可）
3. ❌ Resourcesフィーチャー（MCPコアプリミティブ）
4. ❌ Promptsフィーチャー（MCPコアプリミティブ）

### 修正推奨 (P1):
5. ⚠️ Acceptヘッダー検証
6. ⚠️ SSEイベントID割り当て
7. ⚠️ Content-Typeネゴシエーション
8. ❌ stdioトランスポート

### あると良い (P2):
9. ❌ Samplingフィーチャー
10. ❌ Rootsフィーチャー
11. ❌ イベント再生バッファ
12. ❌ リソーステンプレート

**推奨事項:** まずフェーズ1とフェーズ2に焦点を当て、基本的なMCP準拠とブラウザサポートを達成してください。
