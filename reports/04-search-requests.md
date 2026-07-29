# Search Requests — Pending Web Verification

> **Generated**: 2026-03-07
> **Purpose**: 今回の監査で検出された項目のうち、外部情報の確認が必要なもの。

## How to Use

1. HIGH priority から順に処理
2. 各項目の Suggested Query で検索
3. Status を結果で更新

---

## HIGH Priority — Affects Finding Severity

該当なし。今回の対象はローカルアプリであり、外部ライブラリの CVE 確認は不要。

---

## MEDIUM Priority — Best Practice Verification

### SR-001: macOS Unified Logging の .public プライバシーレベルの可視性

- **Related Finding**: F007, F008, F009
- **What to verify**: macOS 15+ で `.public` レベルのログが管理者以外のユーザーからも `log stream` で参照可能かどうか
- **Suggested query**: `macOS unified logging privacy public access control 2025`
- **Status**: ⬜ Pending
- **Result**:

### SR-002: Unix ドメインソケットの bind→chmod 間の TOCTOU に対する macOS の保護

- **Related Finding**: F012 (appendix)
- **What to verify**: macOS の `/tmp` の sticky bit が bind 済みソケットファイルの置き換えを防ぐかどうか
- **Suggested query**: `macOS /tmp sticky bit unix domain socket race condition`
- **Status**: ⬜ Pending
- **Result**:

---

## LOW Priority — General Knowledge

### SR-003: Swift Foundation Process terminationHandler のスレッド安全性

- **Related Finding**: Fix 2 (ProcessExecutor 修正)
- **What to verify**: `Process.terminationHandler` が `process.run()` 前に設定された場合、Foundation がハンドラの呼び出しを保証するか
- **Suggested query**: `Swift Foundation Process terminationHandler thread safety guarantee`
- **Status**: ⬜ Pending
- **Result**:

---

## Dependency Version Checks

該当なし。ClaudeIsland は Apple フレームワーク（Foundation, SwiftUI, Combine）のみに依存しており、サードパーティライブラリは使用されていない。
