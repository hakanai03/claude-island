# Lessons

## 2026-07-29: subagent完了音・外部ツール名のハードコード

- **パターン**: Claude Code連携の文字列マッチ（ツール名 "Task"、`agent-*.jsonl`のフラット配置、
  hookイベントのstatusマッピング）はClaude Code側の変更で**静かに全滅**する。
  ツール名は "Task" → "Agent" に、subagentトランスクリプトは `<project>/<sessionId>/subagents/` 配下に変わっていた。
- **ルール**:
  - 外部システムの識別子比較は1箇所のヘルパーに集約する（今回: `SubagentState.isSpawnTool`、`ConversationParser.agentFilePath`）。
  - 「〜のはず」のガード（例: `hasActiveSubagent`）が効いていない時は、ガードの入力側（検知経路）が死んでいる可能性をまず疑う。
  - 検証は実データで: `/tmp/claude-island-hook-debug.log` と実トランスクリプト（`~/.claude/projects/`）を見れば実際のツール名・キー・配置がわかる。
- **hookイベントの意味論**: `SubagentStop` はターン途中に発火する（メインはまだ処理継続中）。
  ターン終了は `Stop` のみ。「completed系イベント = 入力待ち」と安易にマップしない。
- **permission通知の二重発火**: Claude Codeは `PermissionRequest`（socket応答可能）の数秒後に
  `Notification`(permission_prompt) を再告知として発火する。後者を新規permission扱いすると
  承認済みでも遅れてUIが出る。ローカルで同名ツールの活動を見ていたらdedupeする。

## 2026-07-29 (続): クリック不能の多層バグ

- **UIイベントの二重系統は必ず衝突する**: グローバル/ローカルNSEventモニタでの自前クリック処理と
  SwiftUIのButtonが同じクリックを取り合っていた。mouseDownでビューを差し替えると
  ButtonのmouseUp発火前に破棄される。パネル内はSwiftUIに委譲、モニタは「外側」だけ扱う。
- **「temporarily」とコメントした状態変更に復元コードが無い**のは典型的バグ
  （NotchPanel.sendEvent の ignoresMouseEvents）。
- **hookのppidは信用しない**: Claude Codeはhookを中間シェル経由で起動することがあり、
  os.getppid() は数十msで死ぬラッパーを指す。後からプロセスツリーを引く設計は
  この時点で破綻する。識別子は「本物のプロセス」まで解決してから報告する。
- **フラグのキャッシュより現物照合**: isInTmux フラグ（起動時計算）より、
  必要時に tty→tmuxペイン照合する方が壊れない。
- **UI検証はユーザーとの対話ループが最速**: AskUserQuestion自体をテストベンチにして
  「押してみて→ログ確認→修正→再テスト」を回した。os_logの計測ログは終わったら消す。

## 環境の罠

- ユーザーのシェルプロファイルに `log` 関数があり `/usr/bin/log` を隠す → unified log操作はフルパスで。
- Xcodeアップデート後に `xcodebuild` がplugin load失敗する場合は `xcodebuild -runFirstLaunch` で修復。
- `screencapture` は画面収録権限がなく失敗する（UI目視検証には使えない）。検証はunified logの
  debugログ（`/usr/bin/log stream --level debug --predicate 'process == "Claude Island"'`）+
  偽hookイベントのsocket注入で行う。
