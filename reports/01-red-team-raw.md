# Red Team Report — Raw Findings

> **Generated**: 2026-03-07
> **Target**: ClaudeIsland (macOS native Swift/SwiftUI app)
> **Phase**: 1 — Attack Surface Discovery

## Project Overview

- **Languages**: Swift 5, Python (hook script)
- **Frameworks**: SwiftUI, Foundation, Combine, os.log (Unified Logging)
- **Entry Points**: Unix domain socket (`/tmp/claude-island.sock`), ファイルシステム監視 (DispatchSource), tmux IPC
- **Authentication**: なし（ソケットはUID制限 `0o600` のみ）
- **Database**: なし（ファイルベースの JSONL ストレージ）

---

## Findings

### [F001] — tmux send-keys によるコマンドインジェクション

- **Category**: A05 — Injection
- **File**: `ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift`
- **Line(s)**: 40, 47-48, 76, 85-86
- **Raw Severity Estimate**: High

**Description**:
`sendKeys(to:keys:pressEnter:)` がユーザーテキストをそのまま tmux `send-keys -l` に渡し、直後に Enter を送信する。`-l` フラグはtmux キー名の解釈を防ぐが、シェルメタ文字のインタープリタは防がない。ターミナルがシェルプロンプト状態であれば任意コマンド実行可能。

**Code Evidence**:
```swift
// ToolApprovalHandler.swift:76
func sendKeys(to target: TmuxTarget, keys: String, pressEnter: Bool = true) async {
    let result = await ProcessExecutor.shared.runWithResult(tmuxPath, arguments: [
        "send-keys", "-t", target.targetString, "-l", keys
    ])
    // ...
    if pressEnter {
        _ = await ProcessExecutor.shared.runWithResult(tmuxPath, arguments: [
            "send-keys", "-t", target.targetString, "Enter"
        ])
    }
}
```

**Attack Scenario**:
1. 悪意あるローカルプロセスがソケット経由で偽の `PermissionRequest` イベントを送信
2. UIがユーザーに承認ダイアログを表示
3. ユーザーが「拒否」を選択し、理由テキストを入力
4. テキストに改行やシェルメタ文字が含まれていれば、tmuxペインのシェルで実行される

---

### [F002] — Unix ソケットの無認証アクセス

- **Category**: A01 — Broken Access Control
- **File**: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- **Line(s)**: 151-185
- **Raw Severity Estimate**: High

**Description**:
`/tmp/claude-island.sock` は `chmod 0o600` で制限されるが、同一 UID の任意のプロセスが接続し、任意の `HookEvent` JSON を送信できる。認証ハンドシェイクや共有シークレットは存在しない。

**Code Evidence**:
```swift
// bind → listen → chmod の順序（bind直後〜chmod前の窓がある）
try socket.bind(to: sockAddr)
try socket.listen(backlog: 5)
chmod(Self.socketPath, 0o600)
```

**Attack Scenario**:
1. 悪意あるプロセスがソケットに接続
2. `PermissionRequest` イベントを偽造し、危険なツール承認をユーザーに促す
3. ユーザーが「承認」すると、実際のClaude CLIセッションに対してキーストロークが送信される

---

### [F003] — transcriptPath によるパストラバーサル（システム的問題）

- **Category**: A01 — Broken Access Control / A05 — Injection
- **File**: `ClaudeIsland/Services/State/SessionStore.swift`, `ConversationParser.swift`, `AgentFileWatcher.swift`, `JSONLInterruptWatcher.swift`
- **Line(s)**: SessionStore:131, ConversationParser:589-594, AgentFileWatcher:47, JSONLInterruptWatcher:47
- **Raw Severity Estimate**: High

**Description**:
`HookEvent.transcriptPath` はソケット経由で受信した外部入力だが、バリデーションなしに `FileHandle(forReadingAtPath:)`, `String(contentsOfFile:)`, `FileManager.contents(atPath:)` 等のファイル操作に直接渡される。攻撃者は任意のファイルパスを指定してファイル読み取りを引き起こせる。

**Code Evidence**:
```swift
// ConversationParser.swift:589
if let registeredPath = transcriptPaths[sessionId] {
    return registeredPath   // バリデーションなしで使用
}
```

**Attack Scenario**:
1. ソケット経由で `transcriptPath: "/etc/passwd"` を含むイベントを送信
2. ConversationParser がそのパスのファイルを読み取り、JSONL としてパース試行
3. JSONL形式のファイルであれば内容がUIに表示される可能性

---

### [F004] — agentId によるパストラバーサル

- **Category**: A05 — Injection
- **File**: `ClaudeIsland/Services/Session/AgentFileWatcher.swift`, `ConversationParser.swift`
- **Line(s)**: AgentFileWatcher:47-53, ConversationParser:1020-1025, 1120-1123
- **Raw Severity Estimate**: High

**Description**:
`agentId` がパス構築に直接使用される: `"agent-" + agentId + ".jsonl"`。`agentId` に `../../` を含めることでディレクトリトラバーサルが可能。

**Code Evidence**:
```swift
self.filePath = dir + "/agent-" + agentId + ".jsonl"
```

**Attack Scenario**:
`agentId = "../../.ssh/id_rsa"` → `~/.claude/projects/<dir>/agent-../../.ssh/id_rsa.jsonl` → `~/.ssh/id_rsa.jsonl`（実在しないが、攻撃パターンとして成立）

---

### [F005] — sessionId によるパストラバーサル

- **Category**: A05 — Injection
- **File**: `ClaudeIsland/Services/Session/ConversationParser.swift`
- **Line(s)**: 593-594
- **Raw Severity Estimate**: Medium

**Description**:
`cwd` は `/` と `.` が `-` に置換されるがm `sessionId` は無加工でパスに使用される。`../` を含む `sessionId` でディレクトリエスケープ可能。

**Code Evidence**:
```swift
return NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"
```

---

### [F006] — デバッグログへの tool_input 書き出し（/tmp）

- **Category**: A09 — Security Logging and Monitoring Failures
- **File**: `ClaudeIsland/Resources/claude-island-state.py`
- **Line(s)**: 97-103
- **Raw Severity Estimate**: High

**Description**:
Python フックスクリプトが `/tmp/claude-island-hook-debug.log` に `tool_input` の最初200文字を平文書き出し。`/tmp` は同一Mac上の全ユーザーが読み取り可能。

**Code Evidence**:
```python
DEBUG_LOG = "/tmp/claude-island-hook-debug.log"
debug_log(f"  tool_input={str(data.get('tool_input', ''))[:200]}")
```

**Attack Scenario**:
同一Macの別ユーザーが `/tmp/claude-island-hook-debug.log` を `tail -f` し、Bashコマンド・ファイルパス・コードスニペットを傍受。

---

### [F007] — ソケットパース失敗時の生データログ出力

- **Category**: A09 — Security Logging and Monitoring Failures
- **File**: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- **Line(s)**: 417
- **Raw Severity Estimate**: High

**Description**:
JSON パース失敗時に受信データ全体が `privacy: .public` でログ出力される。tool_input やメッセージ内容が含まれ得る。

**Code Evidence**:
```swift
logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
```

---

### [F008] — ファイルパス・CWD の .public ログ出力

- **Category**: A09 — Security Logging and Monitoring Failures
- **File**: `AgentFileWatcher.swift`, `JSONLInterruptWatcher.swift`, `TerminalLauncher.swift`
- **Line(s)**: AgentFileWatcher:69, JSONLInterruptWatcher:69, TerminalLauncher:23
- **Raw Severity Estimate**: Medium

**Description**:
ファイルフルパスやCWDが `.public` プライバシーレベルでログ出力。macOS Unified Logging からプロジェクト構造やホームディレクトリパスが漏洩。

---

### [F009] — コマンド引数の .public ログ出力

- **Category**: A09 — Security Logging and Monitoring Failures
- **File**: `ClaudeIsland/Services/Shared/ProcessExecutor.swift`
- **Line(s)**: 99
- **Raw Severity Estimate**: Medium

**Description**:
コマンド失敗時に実行引数全体が `.public` でログ出力。tmux send-keys のキーストロークや対象ペイン名が含まれる。

---

### [F010] — ソケット受信データサイズ制限なし

- **Category**: A10 — Mishandling of Exceptional Conditions
- **File**: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- **Line(s)**: 382-407
- **Raw Severity Estimate**: Medium

**Description**:
ソケット読み取りループに最大サイズ制限がない。悪意あるプロセスが大量データを送信しメモリ枯渇を引き起こせる。

---

### [F011] — TOCTOU: fileExists + FileHandle 開放

- **Category**: A01 — Broken Access Control
- **File**: `AgentFileWatcher.swift`, `ConversationParser.swift`, `JSONLInterruptWatcher.swift`
- **Line(s)**: AgentFileWatcher:67-68, ConversationParser:102-113
- **Raw Severity Estimate**: Medium

**Description**:
`fileExists` チェックと `FileHandle` オープンの間にシンボリックリンクのすり替えが可能（TOCTOU競合）。

---

### [F012] — ソケットパス /tmp の TOCTOU

- **Category**: A02 — Security Misconfiguration
- **File**: `HookSocketServer.swift`, `claude-island-state.py`
- **Line(s)**: HookSocketServer:151-185, Python:12
- **Raw Severity Estimate**: Medium

**Description**:
`/tmp/claude-island.sock` は `bind` → `chmod` の間に世界アクセス可能な窓がある。また `/tmp` は誰でも書き込み可能なので、アプリ起動前に同名ソケットを配置可能。

---

### [F013] — 大規模ファイルの無制限メモリ読み込み

- **Category**: A10 — Mishandling of Exceptional Conditions
- **File**: `ClaudeIsland/Services/Session/ConversationParser.swift`
- **Line(s)**: 112-113
- **Raw Severity Estimate**: Medium

**Description**:
`FileManager.contents(atPath:)` がファイル全体をメモリにロード。サイズ制限なし。

---

### [F014] — HookEvent フィールドの入力検証なし

- **Category**: A05 — Injection
- **File**: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- **Line(s)**: 16-91
- **Raw Severity Estimate**: Medium

**Description**:
`sessionId`, `cwd`, `toolInput`, `message` 等のフィールドに長さ・文字種の検証がない。

---

### [F015] — toolUseIdCache キーに tool_input 全体を保持

- **Category**: A04 — Cryptographic Failures / データ保護
- **File**: `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- **Line(s)**: 301-311
- **Raw Severity Estimate**: Medium

**Description**:
キャッシュキーとして `toolInput` のJSON文字列全体が辞書キーに格納される。

---

### [F016] — Python パスの未固定

- **Category**: A02 — Security Misconfiguration
- **File**: `ClaudeIsland/Services/Hooks/HookInstaller.swift`
- **Line(s)**: 44-45
- **Raw Severity Estimate**: Medium

**Description**:
`python3` をベアパスで使用。`PATH` に悪意あるバイナリが挿入されれば任意コード実行。

---

### [F017] — プロセス実行タイムアウトなし

- **Category**: A10 — Mishandling of Exceptional Conditions
- **File**: `ClaudeIsland/Services/Shared/ProcessExecutor.swift`
- **Line(s)**: 60-195
- **Raw Severity Estimate**: Low

**Description**:
外部プロセス（`/bin/ps`, `tmux`, `yabai` 等）にタイムアウトが設定されていない。

---

### [F018] — キャッシュ・配列の無制限成長

- **Category**: A10 — Mishandling of Exceptional Conditions
- **File**: `AgentFileWatcher.swift`, `HookSocketServer.swift`, `ConversationParser.swift`
- **Line(s)**: AgentFileWatcher:34, HookSocketServer:133, ConversationParser:47
- **Raw Severity Estimate**: Low

**Description**:
`knownTools`, `toolUseIdCache`, `incrementalState` 等のインメモリ構造にサイズ上限がない。

---

### [F019] — settings.json の非アトミック書き込み

- **Category**: A08 — Software and Data Integrity Failures
- **File**: `ClaudeIsland/Services/Hooks/HookInstaller.swift`
- **Line(s)**: 39-98
- **Raw Severity Estimate**: Low

**Description**:
`settings.json` への書き込みがアトミックでなく、同時書き込みでJSON破損の可能性。

---

### [F020] — SwiftUI Text の Markdown 自動解釈

- **Category**: A05 — Injection
- **File**: `ClaudeIsland/UI/Views/NotchView.swift`
- **Line(s)**: 663, 748
- **Raw Severity Estimate**: Low

**Description**:
外部由来テキストが `Text()` で表示される際、SwiftUI の Markdown 解釈により意図しないリンク等が表示される可能性。

---

## Statistics

- Total findings: 20
- By category: A01: 3, A02: 2, A04: 1, A05: 5, A08: 1, A09: 4, A10: 4
- By estimated severity: Critical: 0, High: 7, Medium: 9, Low: 4
- Files analyzed: 15+（主要ファイル全て）
- Coverage notes: UI コンポーネント（ProcessingSpinner, NotchHeaderView）には脆弱性なし。ネットワーク通信なし（ローカルソケットのみ）。
