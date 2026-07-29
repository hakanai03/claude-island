# Blue Team Report — Validated Findings

> **Generated**: 2026-03-07
> **Target**: ClaudeIsland (macOS native Swift/SwiftUI app)
> **Phase**: 2 — Validation & False Positive Filtering
> **Input**: 20 raw findings from Red Team

## Validation Summary

- **Confirmed** (confidence >= 8): 5 findings
- **Appendix** (confidence 5-7): 7 findings (manual review recommended)
- **Rejected**: 8 findings
- **Rejection reasons breakdown**: 設計意図: 2, 既存緩和策: 2, 理論上のみ: 2, 自動除外カテゴリ: 2

---

## Confirmed Findings

### [F006] — デバッグログへの tool_input 書き出し（/tmp）

- **Original Red Team ID**: F006
- **Confidence Score**: 10/10
- **Validated Severity**: High
- **CWE**: CWE-532 — Insertion of Sensitive Information into Log File
- **OWASP**: A09 — Security Logging and Monitoring Failures

**Validation Notes**:
`/tmp/claude-island-hook-debug.log` は `open(DEBUG_LOG, "a")` で作成され、デフォルトの umask（通常 `0022`）により `0644` パーミッションになる。同一 Mac の全ユーザーが読み取り可能。`tool_input` にはBashコマンド、ファイル内容、Edit差分等のセンシティブ情報が含まれる。**コード内に明示的なデバッグフラグ分岐がなく、常時書き出しが行われる。**

**Impact Assessment**:
同一Macの別ユーザー（共有Mac、企業環境）がファイルパス、実行コマンド、コード断片を傍受できる。CI/CD環境やDockerコンテナ内での使用時も `/tmp` は共有される場合がある。

**Remediation**:
```python
# Before:
DEBUG_LOG = "/tmp/claude-island-hook-debug.log"
def debug_log(msg):
    with open(DEBUG_LOG, "a") as f:
        f.write(f"{datetime.now().isoformat()} {msg}\n")

# After: デバッグログを完全に無効化（本番コードに不要）
# DEBUG_LOG 関連のコードをすべて削除
# もしくは環境変数でオプトインにする:
import os
DEBUG_ENABLED = os.environ.get("CLAUDE_ISLAND_DEBUG") == "1"
def debug_log(msg):
    if not DEBUG_ENABLED:
        return
    log_dir = os.path.expanduser("~/.claude/logs")
    os.makedirs(log_dir, mode=0o700, exist_ok=True)
    log_path = os.path.join(log_dir, "hook-debug.log")
    with open(os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "a") as f:
        f.write(f"{datetime.now().isoformat()} {msg}\n")
```

**Remediation Notes**:
最も安全な選択は全デバッグログコードの削除。残す場合は環境変数でオプトインにし、`~/.claude/logs/` に `0o600` パーミッションで作成する。

---

### [F003] — transcriptPath によるパストラバーサル（システム的問題）

- **Original Red Team ID**: F003
- **Confidence Score**: 9/10
- **Validated Severity**: High
- **CWE**: CWE-22 — Improper Limitation of a Pathname to a Restricted Directory
- **OWASP**: A01 — Broken Access Control

**Validation Notes**:
`transcriptPath` はソケット経由の外部入力であり、4箇所（SessionStore, ConversationParser, AgentFileWatcher, JSONLInterruptWatcher）でバリデーションなしにファイル操作に使用される。ソケットは `0o600` 制限だが、同一UID のプロセスは接続可能。Claude CLIフックの外から偽イベントを送信する攻撃パスが存在する。**読み取り専用の影響（任意ファイル読み取り）だが、読み取った内容がUIに表示される可能性がある。**

**Impact Assessment**:
悪意あるローカルプロセスが任意のファイル内容をJSONLとしてパースさせ、パース可能な部分がUIに表示される。直接的なRCEには至らないが、情報漏洩の経路となる。

**Remediation**:
```swift
// SessionStore.swift: processHookEvent 内で一元的にバリデーション
if let transcriptPath = event.transcriptPath {
    let canonicalPath = URL(fileURLWithPath: transcriptPath)
        .standardized.path
    let claudeDir = NSHomeDirectory() + "/.claude/"
    guard canonicalPath.hasPrefix(claudeDir),
          canonicalPath.hasSuffix(".jsonl") else {
        Self.logger.warning("Invalid transcriptPath rejected: \(transcriptPath.prefix(50), privacy: .private)")
        // transcriptPath を無視
        break  // またはこのフィールドだけスキップ
    }
    session.transcriptPath = canonicalPath
    // ...
}
```

**Remediation Notes**:
修正は `SessionStore.processHookEvent` 内の一箇所で実装すれば、下流の全ファイル操作（ConversationParser, AgentFileWatcher, JSONLInterruptWatcher）が保護される。

---

### [F004] — agentId によるパストラバーサル

- **Original Red Team ID**: F004
- **Confidence Score**: 8/10
- **Validated Severity**: Medium
- **CWE**: CWE-22 — Improper Limitation of a Pathname to a Restricted Directory
- **OWASP**: A05 — Injection

**Validation Notes**:
`agentId` は Claude CLI が生成する JSONL ファイルから抽出される。通常は UUID 形式だが、悪意あるプロジェクト（Claude が分析中のリポジトリ）が tool 出力を操作して `agentId` フィールドにトラバーサル文字列を含められる可能性がある。`.jsonl` サフィックスが追加されるため攻撃可能なファイルは限定されるが、`../../` による脱出は成立する。

**Impact Assessment**:
`agentId` に `../../<path>` を注入すると `~/.claude/projects/<dir>/agent-../../<path>.jsonl` となり、`~/<path>.jsonl` のファイルが読み取られる。`.jsonl` サフィックスにより実用的な攻撃対象は限定的。

**Remediation**:
```swift
// AgentFileWatcher init 内、または共通バリデーション関数
guard agentId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
    // agentId が不正 — ウォッチャーを起動しない
    self.filePath = ""
    return
}
```

---

### [F007] — ソケットパース失敗時の生データログ出力

- **Original Red Team ID**: F007
- **Confidence Score**: 9/10
- **Validated Severity**: Medium
- **CWE**: CWE-532 — Insertion of Sensitive Information into Log File
- **OWASP**: A09 — Security Logging and Monitoring Failures

**Validation Notes**:
JSON パース失敗は正常系では稀だが、フック側の Python スクリプトのバグや文字エンコーディング問題で発生し得る。失敗時に受信データ全体が `privacy: .public` で macOS Unified Logging に出力される。このデータには `tool_input`（Bashコマンド等）が含まれ得る。

**Impact Assessment**:
macOS の `log` コマンドまたは Console.app で `.public` レベルのログは閲覧可能。管理者権限があれば他ユーザーのログも参照可能。

**Remediation**:
```swift
// Before:
logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")

// After:
logger.warning("Failed to parse event: \(data.count) bytes from client")
```

---

### [F002] — Unix ソケットの無認証アクセス

- **Original Red Team ID**: F002
- **Confidence Score**: 8/10
- **Validated Severity**: Medium
- **CWE**: CWE-306 — Missing Authentication for Critical Function
- **OWASP**: A01 — Broken Access Control

**Validation Notes**:
ソケットは `0o600` パーミッションで同一 UID に制限されている。macOS のセキュリティモデルでは同一UID = 同一信頼レベルと見なすのが一般的であり、これは設計上の選択とも言える。しかし、Claude Code がサンドボックス外の任意のプロジェクトを処理する際に、プロジェクト内のスクリプトが `HookEvent` を偽造できる点は、信頼境界を超えた攻撃経路として成立する。F003（transcriptPath トラバーサル）との組み合わせでリスクが増大する。

**Impact Assessment**:
偽の PermissionRequest でUIを操作し、ユーザーを騙して承認させる（ソーシャルエンジニアリング的攻撃）。F001（tmux send-keys）との攻撃チェーンで被害拡大。

**Remediation**:
```swift
// 最小限の緩和: 起動時にランダムトークンを生成し、
// Claude CLI フック設定時に環境変数として渡す
// フック → ソケットの接続時にトークンを検証
struct HookEvent: Codable {
    let authToken: String?  // 新規フィールド
    // ...
}

// handleClient 内:
guard event.authToken == expectedToken else {
    logger.warning("Unauthorized socket connection rejected")
    return
}
```

**Remediation Notes**:
この修正は設計変更を伴う。短期的には F003 の transcriptPath バリデーションで最も危険な攻撃経路を塞ぎ、中期的にソケット認証を検討する。

---

## Appendix: Findings Requiring Manual Review (Confidence 5-7)

### [F001] — tmux send-keys によるコマンドインジェクション

- **Confidence Score**: 6/10
- **Reason for uncertainty**: `reject(target:message:)` の `message` 引数の実際のソースを確認する必要がある。UIでユーザーが入力するテキストがそのまま渡される場合は High だが、ユーザー自身がターミナルに入力するのと同等の操作なので、ローカルユーザーが自分のターミナルに入力するコンテキストでは脆弱性とは言えない可能性がある。F002（ソケット偽造）経由の場合のみリスクとなる。
- **Recommended action**: `sendKeys` の全呼び出し元を洗い出し、外部ソースからの入力が流入するパスがあるか確認。

### [F005] — sessionId によるパストラバーサル

- **Confidence Score**: 7/10
- **Reason for uncertainty**: `sessionId` は Claude CLI が生成する UUID 形式の文字列。ソケット経由で任意値を注入可能だが、F002 のソケット認証が前提。`.jsonl` サフィックスにより攻撃対象ファイルが限定。
- **Recommended action**: `sessionId` の UUID 形式チェックを `HookEvent` デコード時に追加。

### [F008] — ファイルパス・CWD の .public ログ出力

- **Confidence Score**: 6/10
- **Reason for uncertainty**: macOS Unified Logging の `.public` は `log stream` コマンドでリアルタイム参照可能だが、通常は管理者権限が必要。共有Mac環境では問題だが、個人Mac環境では低リスク。
- **Recommended action**: `.private` に変更するか、パスの `lastPathComponent` のみを `.public` で出力。

### [F009] — コマンド引数の .public ログ出力

- **Confidence Score**: 5/10
- **Reason for uncertainty**: コマンド失敗時のみ出力。通常運用では稀。引数内容は tmux ターゲット文字列や `"1"`, `"n"` 等の短い文字列が多い。
- **Recommended action**: `arguments` を `.private` に変更。

### [F012] — ソケットパス /tmp の TOCTOU

- **Confidence Score**: 5/10
- **Reason for uncertainty**: `bind` → `chmod` の時間窓は極めて短い（マイクロ秒単位）。実用的な攻撃には精密なタイミングが必要。`/tmp` の sticky bit により他ユーザーはファイル削除不可。
- **Recommended action**: `umask(0o177)` 設定下でソケットを作成し、bind 時点で `0o600` にする。

### [F014] — HookEvent フィールドの入力検証なし

- **Confidence Score**: 6/10
- **Reason for uncertainty**: 個々のフィールドの検証不足は F003, F004, F005 として個別に報告済み。ここでは残りのフィールド（`message`, `toolInput` の長さ制限等）が対象。DoS に分類され、ローカル攻撃者は同等以上のDoS手段を持つため実質的影響は限定的。
- **Recommended action**: ソケット受信データ全体に 1MB の上限を設定（F010）。

### [F016] — Python パスの未固定

- **Confidence Score**: 5/10
- **Reason for uncertainty**: `detectPython()` は `/usr/bin/which python3` を実行し `"python3"` リテラルを返す（which の出力は使わない）。実際の Python パスはフック実行時の `PATH` で解決される。macOS の `/usr/bin/python3` は SIP で保護されている。PATH 汚染にはホームディレクトリの `.bashrc` 等の改竄が必要で、その時点で既に侵害されている。
- **Recommended action**: `/usr/bin/python3` のフルパスを使用することで防御層を追加。

---

## Rejected Findings

| Red Team ID | Title | Rejection Reason |
|-------------|-------|-----------------|
| F010 | ソケット受信データサイズ制限なし | 自動除外: DoS（ローカルソケット、同一UID制限。ローカル攻撃者は直接 kill -9 可能） |
| F011 | TOCTOU: fileExists + FileHandle | 既存緩和策: `FileHandle(forReadingAtPath:)` が nil を返せば後続処理はスキップ。シンボリックリンク攻撃は `~/.claude/projects/` 内限定で影響軽微 |
| F013 | 大規模ファイルの無制限メモリ読み込み | 自動除外: DoS（ローカルファイルの肥大化はローカル攻撃者の権限を超えない） |
| F015 | toolUseIdCache キーに tool_input | 設計意図: キャッシュはインメモリのみで外部露出なし。セッション終了時にクリーンアップ。メモリ効率の問題であり脆弱性ではない |
| F017 | プロセス実行タイムアウトなし | 自動除外: DoS/可用性（Fix 1, Fix 2 で呼び出し頻度は大幅削減済み） |
| F018 | キャッシュ・配列の無制限成長 | 設計意図: セッション寿命にスコープ。現実的なサイズはKB〜数MB。OOM Killer前にアプリ再起動が先 |
| F019 | settings.json の非アトミック書き込み | 理論上のみ: 設定書き込みはアプリ起動時のみで同時アクセスの可能性が極めて低い |
| F020 | SwiftUI Text の Markdown 自動解釈 | 理論上のみ: ローカルUI表示のみ。リモート攻撃経路なし。Markdown リンクをクリックするにはユーザーの意図的操作が必要 |

---

## Observations

- **全体的なセキュリティ姿勢**: macOS ネイティブアプリとして、Unix ドメインソケット (`0o600`) によるプロセス間通信は一般的なアプローチ。ただし `transcriptPath` や `agentId` 等の入力バリデーションが不足しており、ソケット経由の偽造イベントに対する防御が手薄。
- **ログのプライバシー**: `privacy: .public` の使用が広範囲。macOS Unified Logging のアーキテクチャ上、`.public` は永続的にログDBに保存される。開発中は `.public` が便利だが、リリースビルドでは `.private` に切り替えるべき。
- **今回の修正（CPU枯渇パターン修正）による新規脆弱性**: 導入なし。Fix 1（pid チェック）、Fix 2（terminationHandler 化）、Fix 3（インクリメンタルパース）、Fix 4/5（TimelineView 化）はいずれもセキュリティに影響しない純粋なパフォーマンス改善。
