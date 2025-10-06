# StreamingServer デバッグレポート

## 🔍 問題の概要

`streamable_http_server.mojo`の実行時に発生したクラッシュの原因調査と修正プロセスをまとめた。主な問題は接続（`TCPConnection`）の所有権管理とPython依存関係にあった。

## 📋 発生した問題とエラー

### 1. 初期の実行時クラッシュ
```bash
[2685:2685:20251006,131902.992239:ERROR elf_dynamic_array_reader.h:64] tag not found
Please submit a bug report to https://github.com/modular/modular/issues
mojo crashed!
```

### 2. コンパイルエラー（所有権管理）
```bash
error: 'TCPConnection' is not copyable because it has no '__copyinit__'
                    conn,  # This will consume conn
                    ^~~~
```

## 🛠️ 修正プロセス

### Phase 1: Python依存とhex関数の修正

#### 問題のあったコード
```mojo
// stream_manager.mojo
from time import time_ns  // ❌ time_nsが存在しない
var current_time = Float64(time_ns()) / 1_000_000_000.0

// streamable_exchange.mojo
writer.write(hex(len(data)), "\r\n")  // ❌ hex関数が未定義
```

#### 修正内容
```mojo
// stream_manager.mojo
from lightbug_http.mcp.utils import current_time_ms
var current_time = Float64(current_time_ms()) / 1000.0

// mcp/utils.mojo に hex関数を実装
fn hex(value: Int) -> String:
    if value == 0:
        return "0"
    var result = String("")
    var num = value
    var hex_chars = "0123456789abcdef"
    while num > 0:
        var digit = num % 16
        result = hex_chars[digit] + result
        num = num // 16
    return result

// streamable_exchange.mojo
from lightbug_http.mcp.utils import hex
```

**結果:** ✅ コンパイルエラー解決、しかし実行時クラッシュは継続

---

### Phase 2: 接続所有権管理の問題

## 🔄 所有権管理パターンの変遷

### パターンA: 借用から値渡し（失敗）
```mojo
fn serve_connection[T: StreamableHTTPService](
    mut self,
    mut conn: TCPConnection,  // 借用で受け取り
    mut handler: T
) raises -> None:
    // ...
    var exchange = StreamableHTTPExchange.from_connection(
        conn,  // ❌ TCPConnectionはコピーできない
        // ...
    )
```

**エラー:** `'TCPConnection' is not copyable because it has no '__copyinit__'`  
**原因:** `TCPConnection`はコピー不可、借用から値渡しは不可能

---

### パターンB: 所有権取得後のループ継続問題（失敗）
```mojo
fn serve_connection[T: StreamableHTTPService](
    mut self,
    owned conn: TCPConnection,  // 所有権を取得
    mut handler: T
) raises -> None:
    var current_conn = conn^  // 所有権を移動
    
    while True:  // 複数リクエスト処理のループ
        // current_connを使用してリクエスト処理
        var exchange = StreamableHTTPExchange.from_connection(
            current_conn^,  // ❌ 所有権を移動してしまう
            // ...
        )
        // この時点でcurrent_connは無効
        // 次のループ反復で使用できない ❌
    }
```

**問題:** 
- `current_conn^`で所有権を移動すると、次のループで使用不可
- 複数リクエスト処理が不可能

---

### パターンC: 変数混在使用（失敗）
```mojo
fn serve_connection[T: StreamableHTTPService](
    mut self,
    mut conn: TCPConnection,
    mut handler: T
) raises -> None:
    var current_conn = conn^  // current_connに所有権移動
    
    while True:
        var bytes_read = conn.read(temp_buffer)  // ❌ connは既に無効
        if bytes_read == 0:
            current_conn.teardown()  // ✅ current_connは有効
        // ...
        var exchange = StreamableHTTPExchange.from_connection(
            conn^,  // ❌ connは既に無効
            // ...
        )
    }
```

**問題:** `conn`と`current_conn`の使い分けが不一致、一貫性がない

---

### パターンD: 最終修正版（失敗）
```mojo
fn serve[T: StreamableHTTPService](
    mut self,
    owned ln: NoTLSListener,
    mut handler: T
) raises:
    while True:
        var conn = ln.accept()
        try:
            self.serve_connection(conn, handler)  // 借用で渡す
        except e:
            logger.error("Error serving connection:", String(e))
            conn.teardown()  // エラー時にクリーンアップ

fn serve_connection[T: StreamableHTTPService](
    mut self,
    mut conn: TCPConnection,  // 借用で受け取り
    mut handler: T
) raises -> None:
    var current_conn = conn^  // 所有権を取得
    
    // 単一リクエスト処理（ループなし）
    // current_connを一貫して使用
    var bytes_read = current_conn.read(temp_buffer)  // ✅ 一貫性
    
    var exchange = StreamableHTTPExchange.from_connection(
        current_conn^,  // 所有権をexchangeに移動
        // ...
    )
    
    // exchangeから接続を取り戻して終了
    var returned_conn = exchange^.take_connection()
    returned_conn.teardown()
```

**改善点:**
- ✅ 所有権の一貫性を保持
- ✅ エラーハンドリングを追加
- ✅ 単一リクエスト処理に簡素化
- ❌ **最終的にコンパイルエラーで失敗**

---

## 📊 所有権パターン比較表

| パターン | 接続受け取り | 内部処理 | ループ処理 | 結果 | 主な問題 |
|---------|------------|---------|-----------|------|---------|
| A | `mut conn` | `conn` → exchange | 不可 | ❌ コンパイルエラー | コピー不可 |
| B | `owned conn` | `conn^` → `current_conn` | 不可 | ❌ ループ継続不可 | 所有権移動後使用不可 |
| C | `mut conn` | `conn` + `current_conn` 混在 | 不可 | ❌ 一貫性エラー | 変数使い分けミス |
| **D (最終)** | `mut conn` | `conn^` → `current_conn` 一貫 | 単一 | ❌ コンパイルエラー | 所有権管理未解決 |

## 🎯 所有権管理の教訓

### ✅ 正しいパターン
1. **所有権の一貫性:** `current_conn`を作ったら、以後は`current_conn`のみ使用
2. **所有権移動のタイミング:** exchange作成時に`^`で移動
3. **接続の回収:** `exchange^.take_connection()`で回収
4. **エラーハンドリング:** try-catch でconnection cleanup

### ❌ 避けるべきパターン
1. **借用から値渡し:** `mut conn`を直接exchangeに渡す
2. **所有権移動後の使用:** `conn^`後に`conn`を使用
3. **変数の混在使用:** `conn`と`current_conn`を混在
4. **所有権移動後のループ継続:** `current_conn^`後の次回ループ

## 🔧 実施した修正内容

### 1. StreamManager (`lightbug_http/streaming/stream_manager.mojo`)
- ❌ `from time import time_ns`
- ✅ `from lightbug_http.mcp.utils import current_time_ms`

### 2. hex関数 (`lightbug_http/mcp/utils.mojo`)
- ✅ 16進数変換関数を新規実装
- ✅ `streamable_exchange.mojo`と`streamable_body_stream.mojo`でインポート

### 3. StreamingServer (`lightbug_http/streaming/server.mojo`)
- ✅ 接続の所有権管理を統一
- ✅ エラーハンドリングを強化
- ✅ 単一リクエスト処理に簡素化

## 🚨 現在の状況

### ✅ 部分的に解決済み
- Python依存関係の除去
- hex関数の実装

### ❌ **未解決の重大な問題**
- **接続所有権管理が根本的に未解決**
- **コンパイルエラーが継続中**
```bash
error: 'TCPConnection' is not copyable because it has no '__copyinit__'
                    conn,  # This will consume conn
                    ^~~~
```

**現実:** すべての試行パターンが失敗に終わり、動作するStreamingServerは実現できていない

## 📈 学習効果

1. **所有権管理の複雑さ理解:** Mojoでの所有権パターンの難しさを実体験
2. **ポータビリティ向上:** Python依存の除去は成功
3. **デバッグプロセス改善:** 段階的な問題切り分け手法の習得
4. **失敗からの学び:** 4つの異なるアプローチを試行し、それぞれの問題点を特定

## 💡 今後の改善提案

1. **根本的な設計見直し:** StreamingServerのアーキテクチャを再検討
2. **通常のServerパターン活用:** 動作確認済みのパターンを参考に実装
3. **段階的実装:** まず単純な動作版を作成してから機能拡張
4. **Mojoコミュニティ相談:** 所有権管理のベストプラクティスを確認

## 🎓 結論

**正直な評価:**
- ❌ StreamingServerの動作版実現には至らず
- ✅ 問題の特定と分析は成功
- ✅ Python依存除去などの部分的改善は達成
- ✅ Mojoの所有権管理について深い理解を獲得

**次のステップ:** 
根本的な設計アプローチの見直しが必要。現在のパターンではMojoの所有権システムとの互換性に問題がある。

---

*レポート作成日: 2025年10月6日*  
*対象コード: lightbug_http streaming server implementation*
