# UI Test Harness

Claude Island を無人で E2E 検証するためのツール群。アクセシビリティ権限・画面収録権限なしで動く。

## 仕組み

- **fake_ask.py / fake_perm.py** — 偽の hook イベントを `/tmp/claude-island.sock` に注入して
  AskUserQuestion peek / permission peek を表示させる。PermissionRequest は socket を開いたまま待ち、
  アプリの allow/deny 応答を print する。終了時に SessionEnd で偽セッションを掃除する。
  `python3 fake_ask.py <session-id> <wait-sec>`
- **dnpost.swift** — DEBUG ビルドのアプリに入っている UI テストフック
  （NotchWindowController.setupUITestHook）へ Distributed Notification でコマンドを送る。
  クリックは **アプリ内で NSEvent を合成して window.sendEvent に流す**ので、
  レスポンダチェーン→SwiftUI の実経路をそのまま通る（システム権限不要）。
  `dnpost "click:<x>:<yFromTop>"` / `dnpost "open"` / `dnpost "close"`
  座標はスクリーン座標（原点左上）。
- **uitool.swift** — `uitool list` でアプリのウインドウ実フレームを CGWindowList から取得
  （ウインドウがコンテンツにフィットしているかの検証用）。
  `uitool click/move` は CGEvent 送出（アクセシビリティ権限が必要なので通常は使わない）。

## ビルド

```sh
swiftc -o /tmp/uitool scripts/uitest/uitool.swift
swiftc -o /tmp/dnpost scripts/uitest/dnpost.swift
```

## 典型的な検証フロー

```sh
# 1. peek を出す（バックグラウンド、応答待ち 15 秒）
python3 scripts/uitest/fake_ask.py test-session-01 15 > /tmp/result.txt &
sleep 2.5
# 2. ウインドウが peek サイズ（~520x158）に育ったか確認
/tmp/uitool list
# 3. チップ位置をクリック（1つ目のチップは概ね x=690-760, y=70-85）
/tmp/dnpost "click:720:75"
# 4. allow が返れば成功
wait; grep RESPONSE /tmp/result.txt
```

ログ観測は `/usr/bin/log stream --level debug --predicate 'process == "Claude Island"'`
（ユーザーの shell に `log` 関数があるためフルパス必須）。
