# 02-s3-codebuild

S3 に Dockerfile とビルドコンテキストを置き、CodeBuild (VPC モード) でビルド & ECR push する。

## 概要

```
[ローカル PC]                      [AWS]
Dockerfile + src ─→ source.zip
                       │
                       ▼ (マネコンで S3 アップロード)
                    S3 bucket (source)
                       │
                       ▼ (CodeBuild が取得)
                 CodeBuild (VPC mode, private subnet)
                 docker build ─→ docker push ─→ ECR
```

CodeBuild の VPC モードは NAT Gateway なしでも VPC Endpoint 経由で ECR push ができる。
ビルド環境に Docker daemon が組み込まれているため、EC2 管理が不要。

## 前提

- AWS credential が `AWS_PROFILE` などで設定済みであること (terraform apply 用)
- マネジメントコンソールにログインできること (S3 アップロード・CodeBuild 実行用)
- リージョン: ap-northeast-1

## 手順

### 1. apply

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

### 2. ビルドコンテキストを zip にする

```sh
# 例: 簡単な Dockerfile
mkdir -p build-context
cat > build-context/Dockerfile <<'DOCKERFILE'
FROM public.ecr.aws/nginx/nginx:alpine
COPY index.html /usr/share/nginx/html/
DOCKERFILE

echo "<h1>Hello from ECR</h1>" > build-context/index.html

# buildspec.yml も同梱する
cat > build-context/buildspec.yml <<'BUILDSPEC'
version: 0.2
env:
  variables:
    AWS_DEFAULT_REGION: ap-northeast-1
phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
  build:
    commands:
      - echo Building the Docker image...
      - docker build -t $ECR_REPO_URI:$CODEBUILD_RESOLVED_SOURCE_VERSION -t $ECR_REPO_URI:latest .
  post_build:
    commands:
      - echo Pushing the Docker image...
      - docker push $ECR_REPO_URI --all-tags
BUILDSPEC

cd build-context && zip -r ../source.zip . && cd ..
```

> **注意**: `FROM public.ecr.aws/...` は VPC 内からインターネット不通だと pull できない。
> 事前にベースイメージも 01-s3-ec2 の方法で ECR に持ち込み、`FROM <account>.dkr.ecr.<region>.amazonaws.com/base-nginx:alpine` に書き換える必要がある。

### 3. S3 にアップロード (マネコン)

1. AWS マネジメントコンソールで S3 を開く
2. `terraform output` で表示されるソースバケット名を探す
3. `source.zip` をアップロード

### 4. CodeBuild を実行 (マネコン)

1. CodeBuild コンソールを開く
2. `terraform output` で表示されるプロジェクト名を探す
3. 「ビルドの開始」をクリック
4. ビルドログを確認

### 5. ECR でイメージを確認 (マネコン)

1. ECR コンソールでリポジトリを開く
2. push されたイメージのタグを確認

### 6. destroy

```sh
terraform destroy
```

## 結果

- 検証成功 (2026-04-12)
- S3 に source.zip (Dockerfile + index.html + buildspec.yml) をアップロード → CodeBuild で build & ECR push
- ベースイメージは 01-s3-ec2 で ECR に登録済みの nginx:alpine を使用 (`FROM <account>.dkr.ecr.<region>.amazonaws.com/...`)
- ビルド所要時間: 約 52 秒 (PROVISIONING 30s + PRE_BUILD 15s + BUILD 2s + POST_BUILD 3s)
- VPC モードの ENI 作成で PROVISIONING に 30 秒かかる
- **1 回目は失敗**: S3 ソースでは `CODEBUILD_RESOLVED_SOURCE_VERSION` が空になり、`docker build -t $REPO:$VERSION` のタグが不正に。固定タグ (`IMAGE_TAG: latest`) に変更して成功

## 考察

### 良い点

- EC2 の管理が不要 (CodeBuild はフルマネージド)
- ビルドもできる (Dockerfile から構築可能)
- マネコンからワンクリックで実行可能

### 悪い点 / 制約

- ベースイメージの pull にインターネット接続が必要 → private レジストリに事前登録が必要
- VPC Endpoint が複数必要 (S3, ECR api/dkr, CloudWatch Logs)
- CodeBuild の VPC モードは ENI 作成に時間がかかる (起動が遅い)
- buildspec.yml の記述が必要

## メモ

- CodeBuild の特権モード (privilegedMode) が Docker ビルドに必要
- `FROM scratch` や multi-stage build でベースイメージ不要にできるケースもある
- 頻繁に使うなら CodePipeline と組み合わせて S3 アップロード → 自動ビルド も可能
