---
name: post-pr
description: aws-ecs-practice で PR を作成した直後、および PR が merge された後にローカルの jj 状態を整理する手順。bookmark の片付け、merge 済 change の abandon、進行中の別 work の rebase を含む。PR 作成完了時 / PR merge 確認後に呼び出す。
---

# PR 作成〜merge 後の jj 整理

## PR 作成直後

特にローカルでやることはない。CI / review を待つ。
以下のケースが発生したら対応:

### レビュー指摘に対応するとき

該当 change を直接編集:

```sh
jj edit <change-id>
# 修正
jj git push -b <bookmark>   # force update される
```

複数 commit をまとめて修正したい場合は `jj squash` で関連 commit を統合してから push。

### 別の検証を並行で進めたいとき

PR ブランチに依存しない別 work なら main から新規 change を作る:

```sh
jj new main
```

start-work skill 参照。

## PR が merge された後

### 1. origin の最新を取り込む

```sh
jj git fetch
```

### 2. main に merge commit が反映されたか確認

```sh
jj log -r main --no-pager
```

PR の squash merge / merge commit が main の先端にあれば取り込み済み。

### 3. PR の bookmark を後片付け

```sh
jj bookmark forget feat-<topic>
```

GitHub 側で `--delete-branch` していれば remote tracking ブランチも `jj git fetch` で消える。
GitHub の自動ブランチ削除が無効の場合は手動で:

```sh
gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/feat-<topic>
jj git fetch
```

### 4. merge された自分のローカル change を整理

main に squash merge された場合、元のローカル change の内容は main 側に "merge commit" として現れる。
ローカル change はそのままだと **同じ変更が main と自分のローカル両方にある** 状態になる。

```sh
jj log -r 'main..@' --no-pager
```

ローカル change が残っていたら abandon:

```sh
jj abandon <change-id>
```

複数 commit を merge していたら全部:

```sh
jj abandon <root-change>..<top-change>
```

### 5. 進行中の別 work を main に rebase

PR の親に依存していた別ブランチがあれば、新しい main の先端に乗せ直す:

```sh
jj rebase -s <change-id> -d main
```

`-s` (source) を使うこと。`-r` (revision) だと descendants が取り残されて元の親に張り付くので注意。

## 落とし穴

- `jj rebase -r REV -d DEST` は **descendants を移動させない**。descendants も一緒に動かしたいときは `-s SOURCE -d DEST` を使う
- bookmark を移動するだけなら `jj bookmark move <name> --to @` 。`jj bookmark create` で同名を作ろうとすると衝突
- bedrock-iam-role-cost-deny のような未 PR の長期 draft をローカルに残す場合は、明示的に bookmark を切って `(no description set)` 状態を避ける
- `force update` は `jj git push` だけで成立する (jj 側がいい感じに amend 扱いする)。`--force` は通常不要
