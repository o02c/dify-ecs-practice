# 01-s3-ec2

S3 にアップロードした Docker イメージ tar を EC2 で load して ECR に push する。

## 概要

```
[ローカル PC]                  [AWS]
docker save ─→ image.tar.gz
                  │
                  ▼ (マネコンで S3 アップロード)
               S3 bucket
                  │
                  ▼ (S3 Gateway Endpoint)
            EC2 (private subnet)
            docker load ─→ docker tag ─→ docker push ─→ ECR
```

最もシンプルで理解しやすいが、EC2 上で Docker daemon が必要かつ手順が多い。

## 前提

- AWS credential が `AWS_PROFILE` などで設定済みであること (terraform apply 用)
- マネジメントコンソールにログインできること (S3 アップロード用)
- ローカル PC に Docker がインストールされていること
- リージョン: ap-northeast-1

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

### 2. ローカルでイメージを tar に固める

```sh
# 例: nginx をベースにした検証用イメージ
docker pull nginx:alpine
docker tag nginx:alpine test-app:latest
docker save test-app:latest | gzip > test-app.tar.gz
```

### 3. S3 にアップロード (マネコン)

1. AWS マネジメントコンソールで S3 を開く
2. `terraform output` で表示されるバケット名を探す
3. `test-app.tar.gz` をアップロード

### 4. EC2 に SSM Session Manager で接続

```sh
# terraform output から instance_id を取得
aws ssm start-session --target <instance-id>
```

### 5. EC2 上でイメージを load → ECR push

```sh
# S3 からダウンロード
aws s3 cp s3://<bucket-name>/test-app.tar.gz /tmp/

# Docker にロード
docker load < /tmp/test-app.tar.gz

# ECR ログイン
aws ecr get-login-password --region ap-northeast-1 \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com

# タグ付け & push
docker tag test-app:latest <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/<repo-name>:latest
docker push <account-id>.dkr.ecr.ap-northeast-1.amazonaws.com/<repo-name>:latest
```

### 6. destroy

```sh
terraform destroy
```

## 結果

- 全ステップ成功 (2026-04-12)
- `docker save` で 25MB の tar.gz を作成 → S3 アップロード → EC2 で `docker load` → ECR push
- EC2 (t3.medium, Amazon Linux 2023) で Docker daemon 起動確認済み
- S3 → EC2 ダウンロード: 102 MiB/s (S3 Gateway Endpoint 経由)
- ECR push: 全 8 レイヤー push 成功
- SSM Session Manager 経由で EC2 操作 (SSM 系 VPC Endpoint 3 つ必要)

## 考察

### 良い点

- 仕組みがシンプルで理解しやすい
- 特別なツールが不要 (Docker + AWS CLI のみ)

### 悪い点 / 制約

- EC2 を常駐させるか、都度起動する必要がある
- 手順が多く、オペミスしやすい
- Docker daemon が必要 → EC2 のスペックもそれなりに要る

## メモ

- `crane push` を使えば Docker daemon なしで OCI image を push できるが、crane のバイナリを EC2 に持ち込む手段も考える必要がある
- SSM Session Manager を使うには VPC Endpoint (ssm, ssmmessages, ec2messages) が必要
