# Streamable HTTP実装計画（改訂版）

## 研究結果サマリー

### TypeScript SDK分析結果
- **Server-Sent Events (SSE)**: 実際のMCP実装ではSSE + Transfer-Encoding: chunkedの組み合わせを使用
- **ストリーム管理**: `_streamMapping`でアクティブな接続とレスポンスを追跡
- **セッション管理**: ステートフルとステートレス両方のトランスポートモードをサポート
- **エラーハンドリング**: JSON-RPC エラーコードと包括的なヘッダー検証
- **接続クリーンアップ**: リクエスト完了後の自動的なマッピングクリーンアップ
- **セキュリティ**: DNSリバインディング保護とプロトコルバージョン検証

### 現代のHTTPストリーミング動向（2024年）
- **チャンク転送エンコーディング**: HTTP/1.1の標準機能として広く採用
- **フラッシュ機構**: Go（http.Flusher）、Node.js（response.flush）等での実装パターン
- **リアルタイム通信**: SSEがWebSocketの軽量代替として再評価
- **HTTP/2考慮**: Transfer-Encodingヘッダーは禁止、より効率的なストリーミング機構

## 現在の分析結果

### コードベース構造
- **HTTPサーバー**: `server.mojo` - 同期型の単純なHTTP処理
- **リクエスト処理**: `HTTPRequest.from_bytes()` - リクエスト全体をメモリに読み込み
- **レスポンス処理**: `HTTPResponse` - 全データを一度にメモリ内で構築
- **ソケット操作**: `_libc.mojo` - 豊富なPOSIX APIラッパーが実装済み
- **バイト操作**: `io/bytes.mojo` - `ByteWriter`/`ByteReader`が実装済み
- **接続管理**: `connection.mojo` - `Connection`トレイトとTCP実装

### 現在の問題点
1. **メモリ使用量**: 大きなリクエスト/レスポンスを全てメモリに保持
2. **ブロッキング**: リクエスト全体の読み込み完了を待機
3. **非効率**: ストリーミング処理未対応
4. **SSE未サポート**: リアルタイム通信機能なし
5. **接続状態管理なし**: 長時間接続の追跡・管理機能なし

## ハイブリッドアーキテクチャ戦略

### 設計方針
1. **既存API保持**: 現在の同期APIは完全に後方互換性を維持
2. **新API追加**: ストリーミング専用の新しいAPIを並行して提供
3. **段階的移行**: アプリケーションが必要に応じてストリーミングAPIを採用
4. **パフォーマンス最適化**: ゼロコピー操作とバッファプールの活用

## Streamable HTTP実装アプローチ（改訂版）

### フェーズ1: コアストリーミングインフラ（2-3日）

#### 1.1 StreamableBodyStream（新規作成）
`lightbug_http/io/streamable_body_stream.mojo`
```mojo
struct StreamableBodyStream:
    var connection: TCPConnection
    var buffer_size: Int
    var _internal_buffer: Bytes
    var _position: Int
    var _content_length: Optional[Int]
    var _is_chunked: Bool

    fn __init__(mut self, connection: TCPConnection, buffer_size: Int = 4096):
        # 4KB-8KBの最適バッファサイズ

    fn read_chunk(mut self) raises -> Optional[Bytes]:
        # チャンクベース読み込み、部分読み込み対応

    fn write_chunk(mut self, data: Bytes) raises -> Int:
        # Transfer-Encoding: chunked形式での書き込み

    fn write_sse_event(mut self, event_type: String, data: String) raises:
        # Server-Sent Events形式での書き込み

    fn is_complete(self) -> Bool:
        # ストリーム完了判定

    fn flush(mut self) raises:
        # バッファを強制フラッシュ
```

#### 1.2 Connection拡張
`lightbug_http/connection.mojo` の拡張:
```mojo
trait StreamableConnection(Connection):
    fn create_body_stream(self, buffer_size: Int = 4096) raises -> StreamableBodyStream:
        # ストリーミング用ボディストリーム作成

    fn set_streaming_headers(mut self) raises:
        # Transfer-Encoding: chunkedヘッダー設定
```

### フェーズ2: ストリーミングリクエスト/レスポンス（2日）

#### 2.1 StreamableHTTPRequest
`lightbug_http/http/streamable_request.mojo`
```mojo
@value
struct StreamableHTTPRequest:
    var headers: Headers
    var cookies: RequestCookieJar
    var uri: URI
    var method: String
    var protocol: String
    var body_stream: StreamableBodyStream
    var server_is_tls: Bool
    var timeout: Duration

    @staticmethod
    fn from_connection(connection: TCPConnection, addr: String, max_uri_length: Int) raises -> StreamableHTTPRequest:
        # ヘッダーファーストパース、ボディは遅延読み込み

    fn read_body_chunk(mut self) raises -> Optional[Bytes]:
        # ボディをチャンクごとに読み込み

    fn body_iterator(self) -> BodyChunkIterator:
        # イテレーター形式でのボディアクセス
```

#### 2.2 StreamableHTTPResponse
`lightbug_http/http/streamable_response.mojo`
```mojo
@value
struct StreamableHTTPResponse:
    var headers: Headers
    var status_code: Int
    var body_stream: StreamableBodyStream
    var _connection: TCPConnection

    fn __init__(mut self, connection: TCPConnection, status_code: Int = 200):
        # Transfer-Encoding: chunkedヘッダーを自動設定

    fn write_chunk(mut self, data: Bytes) raises:
        # チャンク形式での書き込み

    fn write_sse_event(mut self, event_type: String, data: String) raises:
        # Server-Sent Events書き込み

    fn start_sse_stream(mut self) raises:
        # SSEストリーム開始

    fn end_stream(mut self) raises:
        # ストリーム終了（0サイズチャンク送信）

    fn flush(mut self) raises:
        # バッファフラッシュ
```

### フェーズ3: サーバー統合とセッション管理（2日）

#### 3.1 ストリーム管理システム
`lightbug_http/streaming/stream_manager.mojo`
```mojo
struct StreamManager:
    var _active_streams: Dict[String, StreamableHTTPResponse]
    var _session_mapping: Dict[String, String]  # session_id -> stream_id

    fn register_stream(mut self, stream_id: String, response: StreamableHTTPResponse):
        # ストリーム登録

    fn get_stream(self, stream_id: String) -> Optional[StreamableHTTPResponse]:
        # ストリーム取得

    fn cleanup_stream(mut self, stream_id: String):
        # ストリームクリーンアップ

    fn create_session(mut self) -> String:
        # 新しいセッションID生成
```

#### 3.2 Server拡張
`lightbug_http/server.mojo` の拡張:
```mojo
struct Server:
    # 既存フィールド...
    var _stream_manager: StreamManager
    var _supports_streaming: Bool

    fn listen_and_serve_streaming[T: HTTPService](
        mut self,
        service: T,
        address: String,
        port: Int
    ) raises:
        # ストリーミング対応サーバーループ

    fn handle_streaming_request[T: HTTPService](
        mut self,
        service: T,
        connection: TCPConnection
    ) raises:
        # ストリーミングリクエストハンドラー
```

### フェーズ4: HTTPService拡張（1日）

#### 4.1 StreamableHTTPService trait
```mojo
trait StreamableHTTPService:
    fn call(self, req: StreamableHTTPRequest) raises -> StreamableHTTPResponse:
        # ストリーミング対応サービス

    fn supports_sse(self) -> Bool:
        # SSEサポート確認
```

### フェーズ5: テストと最適化（1-2日）

#### 5.1 テスト戦略
- **単体テスト**: 各ストリーミングコンポーネントの独立テスト
- **統合テスト**: エンドツーエンドストリーミングテスト
- **パフォーマンステスト**: 大量データストリーミング性能測定
- **メモリテスト**: メモリ使用量とリーク検出
- **SSEテスト**: Server-Sent Events機能テスト

## 技術仕様詳細

### チャンク転送エンコーディング実装
```mojo
fn format_chunk(data: Bytes) -> Bytes:
    # RFC 9112準拠のチャンク形式
    var chunk_size = hex(len(data))
    return bytes(chunk_size + "\r\n") + data + bytes("\r\n")

fn format_final_chunk() -> Bytes:
    return bytes("0\r\n\r\n")  # 終了チャンク
```

### Server-Sent Events実装
```mojo
fn format_sse_event(event_type: String, data: String, id: Optional[String] = None) -> String:
    var result = "event: " + event_type + "\n"
    if id:
        result += "id: " + id.value() + "\n"
    result += "data: " + data + "\n\n"
    return result
```

### エラーハンドリング戦略
```mojo
@value
struct StreamingError(Error):
    var code: Int
    var message: String

    alias CONNECTION_CLOSED = StreamingError(1001, "Connection closed by client")
    alias BUFFER_OVERFLOW = StreamingError(1002, "Buffer overflow")
    alias INVALID_CHUNK = StreamingError(1003, "Invalid chunk format")
    alias SSE_FORMAT_ERROR = StreamingError(1004, "SSE format error")

fn handle_streaming_error(error: StreamingError, connection: TCPConnection):
    # 適切なHTTPエラーレスポンス送信とクリーンアップ
```

## パフォーマンス最適化

### バッファ管理
- **バッファプール**: 頻繁な割り当て/解放を避けるための再利用可能バッファ
- **適応的バッファサイズ**: トラフィック量に基づく動的サイズ調整
- **ゼロコピー操作**: Mojoの所有権システムを活用したメモリコピー削減

### 接続管理
- **Keep-Alive サポート**: HTTP/1.1 persistent connections
- **接続プール**: クライアント側での接続再利用
- **タイムアウト管理**: 非アクティブ接続の自動クリーンアップ

## 実装見積もり（改訂版）

### 詳細工数見積もり
- **フェーズ1 - コアインフラ**: 2-3日
  - StreamableBodyStream実装: 1.5日
  - Connection拡張: 0.5-1日
- **フェーズ2 - Request/Response**: 2日
  - StreamableHTTPRequest: 1日
  - StreamableHTTPResponse: 1日
- **フェーズ3 - サーバー統合**: 2日
  - StreamManager実装: 1日
  - Server統合: 1日
- **フェーズ4 - Service拡張**: 1日
- **フェーズ5 - テスト・最適化**: 1-2日

**総見積もり**: 8-10日間

### リスク要因
- **POSIX API互換性**: 異なるOS間での動作確認
- **メモリ管理**: Mojoの所有権システムとの統合複雑性
- **パフォーマンス調整**: 最適なバッファサイズの決定
- **エラーハンドリング**: 予期しない接続切断への対応

## 移行戦略

### 段階的移行パス
1. **Phase 1**: 新しいストリーミングAPIを既存コードベースに追加
2. **Phase 2**: 既存アプリケーションでの限定的なストリーミング機能テスト
3. **Phase 3**: 高負荷部分から段階的にストリーミングAPIに移行
4. **Phase 4**: 全面的なストリーミング対応（オプション）

### 互換性保証
- 既存の`HTTPRequest`/`HTTPResponse`は完全に機能維持
- 既存の`HTTPService`実装は変更不要
- 新機能は明示的にopt-inする設計

## 実装優先順位

### 最小機能セット（MVP）
1. 基本的なチャンク転送エンコーディング
2. ストリーミングRequest/Response
3. 基本的なエラーハンドリング

### 拡張機能セット
1. Server-Sent Events サポート
2. セッション管理
3. パフォーマンス最適化
4. 包括的なテストスイート

この計画により、lightbug_httpは現代的で効率的なストリーミングHTTPライブラリとして進化し、MCP（Model Context Protocol）などの高度な用途にも対応できるようになります。