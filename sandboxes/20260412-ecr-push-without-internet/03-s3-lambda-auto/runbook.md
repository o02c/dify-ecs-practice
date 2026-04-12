# 03-s3-lambda-auto

S3 にイメージ tar をアップロードすると、EventBridge + Lambda で自動的に ECR に push する。

## 概要

```
[ローカル PC]                      [AWS]
docker save ─→ image.tar.gz
                  │
                  ▼ (マネコンで S3 アップロード)
               S3 bucket
                  │
                  ▼ (EventBridge: PutObject イベント)
               Lambda (VPC 内, crane バイナリ同梱)
                  │
                  ▼ (ECR VPC Endpoint)
               ECR repository
```

01-s3-ec2 の手動作業 (docker load → tag → push) を Lambda + crane で自動化する。
Docker daemon 不要で、EC2 の管理も不要。

## 前提

- AWS credential が `AWS_PROFILE` などで設定済みであること (terraform apply 用)
- マネジメントコンソールにログインできること (S3 アップロード用)
- ローカル PC に Docker がインストールされていること (docker save 用)
- リージョン: ap-northeast-1

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

terraform apply 時に crane バイナリのダウンロードと Lambda zip のビルドが自動で行われる。

### 2. ローカルでイメージを tar に固める

```sh
docker pull nginx:alpine
docker tag nginx:alpine test-app:latest
docker save test-app:latest | gzip > test-app.tar.gz
```

### 3. S3 にアップロード (マネコン or CLI)

```sh
# terraform output で表示されるバケット名を使用
aws s3 cp test-app.tar.gz s3://<bucket-name>/test-app.tar.gz
```

アップロード完了後、EventBridge → Lambda が自動起動し、ECR に push される。

### 4. 確認

```sh
# Lambda の実行ログ
aws logs tail /aws/lambda/<function-name> --follow

# ECR にイメージが入ったか
aws ecr describe-images --repository-name <repo-name>
```

### 5. destroy

```sh
terraform destroy
```

## 結果

- 検証成功 (2026-04-12)
- S3 に tar.gz アップロード → EventBridge が検知 → Lambda が自動起動 → crane で ECR push
- S3 アップロードから ECR push 完了まで約 15 秒 (Lambda 実行時間)
- **修正が必要だった点**:
  1. Lambda の `/home` は read-only → `DOCKER_CONFIG=/tmp/.docker` を設定して crane の認証情報保存先を変更
  2. `crane push` は非圧縮 tar を期待 → `.tar.gz` の場合は事前に gunzip が必要
- ファイル名からタグ決定: `test-app.tar.gz` → ECR tag `test-app`
- Lambda メモリ使用量: 191 MB / 512 MB (余裕あり)
- Ephemeral storage: 展開後 60.1 MB / 2048 MB

## 考察

### 良い点

- 完全自動化: S3 アップロードだけでイメージが ECR に登録される
- EC2 / Docker daemon 不要 (crane バイナリが docker save 形式を直接 push)
- サーバーレスで管理コスト最小

### 悪い点 / 制約

- Lambda の /tmp は最大 10GB (ephemeral storage 設定) → 大きなイメージは不可
- Lambda タイムアウト最大 15 分 → 巨大イメージは時間切れリスク
- crane バイナリを Lambda パッケージに同梱する必要がある
- ビルドはできない (tar の push のみ)

## メモ

- crane は Google が開発した Go 製ツールで、Docker daemon なしで OCI イメージ操作が可能
- `docker save` 形式 (v1) も `crane push` が対応している
- S3 のオブジェクトキーから ECR のタグを決定するロジックは Lambda 側で自由に変更可能
