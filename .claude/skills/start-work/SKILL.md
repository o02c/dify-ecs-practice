---
name: start-work
description: aws-ecs-practice で新しい sandbox や検証を始めるときに使う。jj git fetch で最新を取り込み、main から新規 change を作るところまでをガイドする。新規タスク開始 / 新しい sandbox を切る / 既存ローカル変更が散らかった状態から仕切り直すときに呼び出す。
---

# 新規作業の開始手順 (jj)

このリポジトリは jj 必須 (CLAUDE.md 参照)。新規 sandbox / 検証を始めるときは以下の手順を踏むこと。

## 0. AWS_PROFILE 確認

このリポジトリで AWS を叩くときは既定で `AWS_PROFILE=terraform` を使う (CLAUDE.md)。シェルで設定済みかチェック。

## 1. origin から最新を取得

```sh
jj git fetch
```

`Nothing changed.` でも OK (既に最新)。

## 2. main と `@` の関係を確認

```sh
jj log -r 'all() & ~empty()' --no-pager | head -20
```

確認ポイント:

- `@` が `main` の直接子孫になっているか
- 旧 main から派生したまま放置された "no description set" の draft commit が無いか
- 未 PR のローカル change があるか (あれば責務ごとに `jj describe` で名前付けしておく)

`@` が古い祖先から伸びている場合は **必ず先に rebase** する。後で PR を作ると差分が壊れる:

```sh
jj rebase -s @ -d main
```

## 3. ローカルに溜まった draft commit を整理 (必要なら)

このリポジトリでは過去に "no description set" の超大 draft commit に複数 sandbox を詰め込む癖が観測されている。`jj split` でテーマごとに切り分ける:

```sh
JJ_EDITOR=true jj split -r <change-id> <paths>...
jj describe <change-id> -m "..."
```

description を都度書く方が後で楽。

## 4. 新規 change を main から作る

```sh
jj new main
```

これで `@` が main の直接子になる。

## 5. sandbox 雛形をコピー (このリポジトリの慣例)

```sh
cp -r _template sandboxes/$(date +%Y%m%d)-<topic>
```

`<topic>` には kebab-case で課題を表す短い名前を入れる (例: `ses-email-receiving`)。

## 6. bookmark は後で作って OK

PR を出す段階で:

```sh
jj bookmark create feat-<topic> -r @
jj git push -b feat-<topic> --allow-new
```

## 落とし穴

- `@` が古い HEAD に乗っていることがある。main との関係を必ず確認する
- jj は無 description の draft に変更を溜めがち。意味のまとまりごとに `jj describe` する習慣を
- `.DS_Store` / `**/terraform/.build/` / `.claude/scheduled_tasks.lock` は `.gitignore` 済み (誤って track した場合は `jj file untrack` か `jj restore --from main --to @ <path>` で剥がす)
- `_template` を `cp -r` した直後はまだ `terraform/` の中身が空。書き始めてから `terraform init`
