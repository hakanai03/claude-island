# Claude Island 改善 TODO

## ウインドウ/イベント層の作り直し (2026-07-29, branch: rework-window-events)

- [x] 全幅750pt透明ウインドウ + クリック素通り細工（CGEvent repost / sendEventオーバーライド /
  カスタムhitTestRect / グローバルmouseMoved監視）を全廃
- [x] ウインドウを表示内容にフィットさせて top-center 固定（閉: ノッチ+活動バー幅, 開: パネル+影マージン）
  → AppKit標準のヒットテストがそのまま効く。拡大は即時・縮小はクローズアニメ後0.6s
- [x] hover開閉を SwiftUI .onHover 駆動に（全マウス移動でのプロセス起床が消えてCPUにも効く）
- [x] 外側クリックでクローズはグローバルmouseDown監視1本のみ（クリックは背後アプリに自然に届くのでrepost不要）
- [x] ヘッダー帯タップ: peek→chat展開 / chat維持 / その他クローズ
- [x] DEBUGビルド限定のUIテストフック（Distributed Notification → アプリ内NSEvent合成）
  → scripts/uitest/ に無人E2Eハーネス一式（README参照）
- [x] 無人回帰テスト: 閉フレーム / 開フレーム / ヘッダークローズ / チップ→allow /
  permission Allowボタン / 質問文→chat展開（+ ユーザー実クリックでもチップ動作確認済み）
- [x] 実マウス検証: チップクリック・chat送信・一覧オープン・クラッシュ根治をユーザー確認済み
- [ ] 残チェック: ノッチホバー1秒で開く（ホットスポット窓経由に変わった）/
  サウンドピッカー展開の表示 / 外部ディスプレイ構成
- [ ] 安定運用を数日見たら scripts/build.sh でリリースビルド → /Applications 差し替え
  （ログイン項目が古いリリース版のままなので、Mac再起動で古いのが復活する）

## Done (今回のセッション)

- [x] AskUserQuestion: UI内で質問表示 + オプションチップ + テキスト入力で回答
- [x] AskUserQuestion: インスタンス一覧に実際の質問テキスト表示
- [x] ExitPlanMode: Markdownレンダリングでプラン全文表示
- [x] ExitPlanMode: allowedPrompts 情報表示
- [x] findTmuxTarget を ClaudeSessionMonitor に共通化

## CPU枯渇パターン修正（第2弾）

- [x] Fix 1: processHookEvent内のbuildTree()をpid変更時のみに限定 [Critical]
- [x] Fix 2: ProcessExecutor.runWithResult()をterminationHandler使用で非ブロッキング化 [Critical]
- [x] Fix 3: AgentFileWatcher.parseTools()をインクリメンタルパース化（lastOffsetから差分のみ読み込み） [High]
- [x] Fix 4: ProcessingSpinnerをTimelineViewに置換（Timer.publish廃止） [Medium]
- [x] Fix 5: ClaudeCrabIconのタイマーをTimelineView(.animation(paused:))に置換 [Medium]

## 「要input」キュー UI（ユーザー提案 2026-07-29）

- [x] 第1弾: peekを要inputスタックリスト化（bb579e9）
  - 複数セッションのask/permissionを1つのpeekに積んで表示（セッション名+チップ/Allow/Deny）
  - 入力が残っている間はpeekが閉じない・件数でリサイズ・全部捌けたら自動クローズ
  - 無人E2E検証済み（2件スタック→各行操作→自動クローズ）
- [ ] 第2弾: 手動で開いたinstances画面にも同じキューをセクション表示する
- [ ] 第3弾: subagent発permissionの行に [agent名] 表示を統合（peekPermissionContentは対応済み、
  行レイアウトの見直しと合わせて）

## UI改善

- [x] 複数セッション時にクロードくんアイコンを重ねて表示（2匹、3匹...）
- [x] チェックマーク自動消去: 30秒→10秒に短縮
- [x] cmux対応: TTYがあればtmuxなしでもチャットUI表示可能 + TTY直接入力フォールバック
- [x] ツール承認バー情報充実化: Bashコマンド・description・ファイルパスを表示
- [x] PlanApprovalBar: 表示領域を拡大（minHeight: 350）
- [x] Agent team: サブエージェントを親セッション下にインデント表示 + 折りたたみUI
- [ ] PlanApprovalBar: auto-acceptボタン（セッション単位でツール承認を自動化）
  - hook system は allow/deny のみ。セッション単位の auto-approve フラグが必要
- [ ] AskUserQuestion: 質問終了後の ? アイコン / thinking animation が残る問題（保留）
- [ ] AskUserQuestion: 過去の回答履歴表示
- [ ] multiSelect 対応（複数選択 AskUserQuestion）
- [ ] AskUserQuestion 複数質問対応: parse が questions.first のみ。island には1問目しか出ず、
  チップ回答も1問目にしか効かない（CLIのReview/Submit画面も未考慮）

## バグ

- [x] subagent完了時に完了音が鳴る問題の修正
  - [x] hook: SubagentStop を waiting_for_input → processing に変更（ターン終了は Stop が担う）
  - [x] Swift: subagent起動ツール名 "Task" → "Task"/"Agent" 両対応（現行Claude Codeは "Agent"。追跡が全死していた）
  - [x] ビルド → 常駐リリース版をkill → 開発版を起動 → 偽hookイベントで検証（Agent追跡ログ確認、SubagentStopでwaitingForInputにならないこと確認）
- [x] AskUserQuestion: island上の選択肢チップが機能しない（E2Eで修正確認済み）
  - 原因1: peek表示中のグローバル/ローカルイベントモニタが、パネル内クリックをmouseDown時に
    contentType切替へ横取りし、ButtonのmouseUpが発火する前にビューを破棄していた
    → パネル内クリックはSwiftUIのボタンに委譲するよう修正 (NotchViewModel.handleMouseDown)
  - 原因2: NotchPanel.sendEventのパススルーで ignoresMouseEvents=true にした後の復元が無かった
    → repost後に shouldAcceptMouseEvents で復元
  - 原因3: 非キーウインドウで初回クリックが吸われる → PassThroughHostingView.acceptsFirstMouse=true
  - 原因4(真因・最重要): hookが報告するpidが短命なラッパーシェルのもので、アプリがプロセスツリーを
    引く時点で消滅 → isInTmux が常にfalse → tmux send-keysによる回答入力が全skip
    → hook側で祖先を辿って本物のclaudeプロセスpidを解決 (get_claude_pid)
    → Swift側も tty→tmuxペイン照合でターゲットを直接解決（フラグ非依存）
- [x] 「Teammate: Permission」という謎の選択肢が遅れて出る問題
  - ツール名なしの "Claude needs your permission" 通知がデデュープをすり抜けていた
  - ローカルツール活動が90秒以内にあるセッションでは、ツール名なし通知も再告知として無視
- [x] permission request が承認後に時間差で届く問題
  - 原因: Claude Codeが PermissionRequest の約6秒後に Notification(permission_prompt) を再告知として発火。
    アプリがこれを新規permission（`notification-<UUID>`）として扱い、承認済みでも遅れてpeekが出ていた
  - 修正: SessionStoreでdedupe（phase既にwaitingForApproval、または同名ツールのローカル活動が90秒以内なら無視。
    team modeのteammate転送プロンプトはローカル活動が無いので従来どおり表示）
- [x] subagentのツールがメイン会話に平置きされて溢れる問題（"Task"→"Agent"対応で`hasActiveSubagent`ガード復活により解消）
- [x] subagentツールの入れ子表示が空になる問題（新配置 `<project>/<sessionId>/subagents/agent-*.jsonl` に対応。
  `ConversationParser.agentFilePath` に集約、AgentFileWatcherも同ヘルパー使用）
- [ ] subagentが会話一覧に別エントリとして出る問題: hookイベントは全て親session_idで届くことを実測確認済みで、
  Agent toolのsubagentは一覧に出ない構造。再発したらどのセッションが出たか（teammate? 別プロセス?）の具体例がほしい
- [ ] tmux / cmux: テキストinputからの送信が効かない
  - 真因は上記のpid問題の可能性大（isInTmux=false で送信経路が死ぬ）。hook修正後に再検証を。
    ChatViewの入力送信経路も answerQuestion と同様に tty→tmuxペイン照合へ寄せると堅い
- [ ] Agent team: yes/no承認リクエストが飛んでこない
- [ ] ターミナルフォーカスボタン: claudeが動いてるウインドウにフォーカスするボタン

## 将来的な改善

- [ ] tmux pane 内容ポーリング: ソケット応答→tmuxタイプの間に描画完了を確認してからタイプ
- [ ] diff表示の改善: コード変更時に表示領域を広げる
