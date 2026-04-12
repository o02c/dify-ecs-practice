# ECR push without internet — S3 経由でイメージを持ち込む

> 検証日: 2026-04-12
> Obsidian: [[TODO]]

## 背景 / 課題

以下の制約がある環境で ECR にコンテナイメージを登録したい。

- **AWS API の外部利用不可** — ローカル PC から AWS CLI/SDK を直接叩けない
- **マネジメントコンソール接続 OK** — ブラウザ経由で S3 アップロード等は可能
- **VPC 内からインターネット接続不可** — `docker build` (base image pull) ができない
- **VPC 内から ECR への push は可能** — VPC エンドポイント経由

つまり「イメージを VPC 内に持ち込む手段」が課題の核心。

## 仮説

- S3 をイメージの受け渡しバケツとして使えば、マネコン経由でアップロード → VPC 内からダウンロード → ECR push の経路が成立する
- `docker save/load` を使う素朴な方法と、CodeBuild に任せる方法で運用負荷が変わるはず

## 検証環境

- VPC (private subnet only) + VPC Endpoints (S3 Gateway, ECR api/dkr, CloudWatch Logs)
- ECR リポジトリ
- 01: EC2 (Docker 入り) in private subnet + SSM Session Manager
- 02: CodeBuild (VPC モード) + S3 ソースバケット

## Approach 比較

| #  | Approach      | 概要                                         | コスト       | 運用負荷 | 制約 / 適用条件                    | 結果 |
|----|---------------|----------------------------------------------|-------------|---------|-----------------------------------|------|
| 01 | S3 + EC2      | docker save → S3 → EC2 で load → ECR push    | EC2 常駐    | 高 (手動) | Docker daemon 必要、手順が多い      | 成功 |
| 02 | S3 + CodeBuild | Dockerfile+context を S3 → CodeBuild で build & push | 実行時のみ | 低 (自動) | CodeBuild の VPC モード + Endpoints 必要 | 成功 |
| 03 | S3 + Lambda (自動) | S3 put → EventBridge → Lambda (crane) → ECR push | 実行時のみ | 最低 (全自動) | ビルド不可 (tar push のみ)、Lambda サイズ制限 | 成功 |

詳細は各 approach の `runbook.md` を参照。

## 結論 / 学び

- どちらのアプローチも S3 を中継点として ECR push が可能
- **既存イメージをそのまま持ち込むだけなら 01 (S3 + EC2)** が最もシンプル
- **Dockerfile からビルドしたい場合は 02 (S3 + CodeBuild)** が EC2 管理不要で楽。ただしベースイメージは事前に ECR に登録しておく必要がある (結局 01 が先に必要)
- **ビルド不要で自動化したいなら 03 (S3 + Lambda)** が最も運用負荷が低い。S3 にアップロードするだけで完了
- VPC Endpoint のコストに注意: Interface Endpoint は 1 つあたり ~$0.014/h × AZ 数。01 は 5 つ (ECR 2 + SSM 3)、02 は 3 つ (ECR 2 + Logs 1)、03 は 2 つ (ECR 2) + S3 Gateway (無料)
- CodeBuild の S3 ソースでは `CODEBUILD_RESOLVED_SOURCE_VERSION` が空になるため、タグは自前で指定する必要がある
- Lambda で crane を使う場合、`DOCKER_CONFIG=/tmp/.docker` の設定と tar.gz の事前展開が必要

## 関連リンク

- AWS Docs: [VPC endpoints for Amazon ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)
- AWS Docs: [CodeBuild in VPC](https://docs.aws.amazon.com/codebuild/latest/userguide/vpc-support.html)
