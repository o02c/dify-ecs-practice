# 01-example

<!-- この approach の 1 行サマリ -->

## 概要

<!-- どんな構成で何を確かめるのか。トレードオフを含めて書く。 -->

## 前提

- AWS credential が `AWS_PROFILE` などで設定済みであること
- リージョン: ap-northeast-1 (必要に応じて変更)
- 必要な IAM 権限: <ECS / VPC / IAM など>

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

### 2. 検証

<!-- 何を観測するか。実行するコマンド、確認するメトリクス、ログのフィルタなど。 -->

```sh
# 例: タスク一覧
aws ecs list-tasks --cluster <cluster-name>
```

### 3. destroy

```sh
terraform destroy
```

## 結果

<!-- 実際に観測されたこと。ログやメトリクスの抜粋を貼る。 -->

## 考察

<!-- 仮説に対する答え。良い点 / 悪い点 / 制約。 -->

### 良い点

-

### 悪い点 / 制約

-

## メモ

<!-- 検証中に気付いたこと、引っかかったポイントなど。 -->
