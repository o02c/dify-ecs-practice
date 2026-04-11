# aws-ecs-practice

ECS まわりで遭遇した課題に対して、terraform で sandbox を立ち上げて検証するためのリポジトリ。

最終的なレポートは Obsidian で管理する。このリポジトリには **再現に必要な terraform と作業手順** と、Obsidian へ転記する素材を残す。

## ディレクトリ構成

```
.
├── _template/            新しい検証を始めるときのコピー元
└── sandboxes/
    └── YYYYMMDD-<topic>/ 1 つの「課題」= 1 ディレクトリ
        ├── README.md     課題 / 仮説 / 各 approach の比較 / 結論
        ├── 01-<approach>/
        │   ├── runbook.md  手順 + 結果 + 考察
        │   └── terraform/
        └── 02-<approach>/
            ├── runbook.md
            └── terraform/
```

### 設計方針

- **DRY にしない**: approach 間で構成が被ってもコピペで済ませる。各 approach は独立して `apply` / `destroy` できる状態を保つ。
- **1 課題 = 1 ディレクトリ**: 課題のトップ `README.md` に全 approach の比較と結論をまとめ、Obsidian への転記元にする。
- **1 approach = `runbook.md` + `terraform/`**: 各 approach は手順・結果・考察を `runbook.md` に集約し、構成は `terraform/` に置く。
- **terraform backend は local**: tfstate は各 approach ディレクトリのローカルに置き、検証後は `destroy` してから捨てる。
- **AWS credential は環境側で指定**: terraform 側で profile を指定しない。`AWS_PROFILE` / `AWS_REGION` などを実行環境で設定する。

## 新しい検証を始めるとき

```sh
cp -r _template sandboxes/$(date +%Y%m%d)-<topic>
```

中身を書き換えて検証を開始する。approach が増えたら `01-<approach>/` をディレクトリごとコピーして `02-<approach>/` を作る。
