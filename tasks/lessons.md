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

## 2026-07-29 (続々): ウインドウ作り直しと無人UI検証

- **オーバーサイズ透明ウインドウは負債の親**: 「全画面幅ウインドウ+クリック素通り細工」を選ぶと
  repost/ignoresMouseEvents/カスタムhitTestの3点セットが芋づるで必要になる。
  ウインドウを見た目にフィットさせれば全部消える。
- **SwiftUIのButtonは`.frame(maxWidth: .infinity)`だけでは全域タップ不可** —
  透明領域は `.contentShape(Rectangle())` が要る。
- **無人UI検証の型**: ①偽hookイベント注入で状態を作る → ②CGWindowListでウインドウ実フレームを
  検証 → ③DEBUG限定フック（Distributed Notification → アプリ内NSEvent合成 → window.sendEvent）で
  クリックを実経路に流す → ④socket応答/フレーム変化で判定。アクセシビリティ権限不要。
  ツール一式: scripts/uitest/（README あり）。
- CGEvent での外部からの合成クリックは Accessibility 権限がないと**無言で捨てられる**
  （エラーも出ない）。カーソル位置の変化で効いているか必ず確認する。
- probe座標は数pxでフレークする。グリッドで撃って成功条件（socket応答/フレーム変化）で判定する。

## 2026-07-29 (最終盤): NSHostingView × ウインドウ動的リサイズのクラッシュ3連

macOS 26でNSHostingViewを載せたウインドウを自前でsetFrameし続けると、SwiftUIの再無効化が
AppKitのレイアウト/制約パス内に食い込み `NSInternalInconsistencyException` で落ちる。3経路あった:
1. `updateConstraints`内のウインドウ理想サイズ管理 → `sizingOptions = []` で無効化
2. リサイズ時のsafe area角インセット再計算 → `safeAreaRegions = []` で無効化
3. `rootTransform`のウインドウ内ジオメトリ監視 → `setFrame(display: false)` で表示処理を
   サイクル外へ逃がす（macOS 26のUpdateCycleドライバはdispatch mainブロックをサイクル内で
   処理し得るため、display: trueだと同期表示がパス内に食い込む）
- クラッシュ再現は「アニメーション常時稼働セッション + 連続ask」のストレスで行う
  （単発では再現しないレース）。クラッシュレポートは lastExceptionBacktrace を見る。
- **最終結論: 経路を塞ぐモグラ叩きでは勝てない（3連敗）。「NSHostingViewのウインドウは
  リサイズしない」が正解**。固定サイズの包絡ウインドウ（開時のみクリック受付、
  パネル外クリックはscrimでdismiss）+ ノッチ上の素AppKitホットスポット窓（閉時のhover/click）
  の2窓構成に落ち着いた。ユーザー実再現手順で根治確認済み (2a77eac)。

## 環境の罠

- ユーザーのシェルプロファイルに `log` 関数があり `/usr/bin/log` を隠す → unified log操作はフルパスで。
- Xcodeアップデート後に `xcodebuild` がplugin load失敗する場合は `xcodebuild -runFirstLaunch` で修復。
- `screencapture` は画面収録権限がなく失敗する（UI目視検証には使えない）。検証はunified logの
  debugログ（`/usr/bin/log stream --level debug --predicate 'process == "Claude Island"'`）+
  偽hookイベントのsocket注入で行う。
