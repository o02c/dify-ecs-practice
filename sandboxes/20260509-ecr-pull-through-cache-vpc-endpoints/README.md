# ECR Pull Through Cache — VPC エンドポイントだけの環境で初回 pull できるか

> 検証日: 2026-05-09
> Obsidian: [[TODO]]

## 背景 / 課題

`20260412-ecr-push-without-internet` では **「インターネット不可な環境にどうイメージを持ち込むか」** を検証した (S3 経由で push)。
今回はその **「pull 側」** の話。

ECR Pull Through Cache (PTC) は cache miss 時に ECR 自身が上流レジストリ (Docker Hub / ECR Public / Quay / GHCR / GitLab / Kubernetes / Azure / Chainguard) からイメージを取得して private repo にキャッシュする機能。
**上流への通信は ECR サービス側で完結する**ように見えるが、実際にクライアント側がインターネット不可 (= VPC エンドポイント経由のみ) でも初回 pull (cache miss) が成立するのかを実機で確かめる。

成立すれば「インターネット不可環境でも `docker pull` 1 発でベースイメージを引ける」運用が成立し、前回サンドボックスの S3 中継方式が不要になるケースが多くなる。

## 仮説

- PTC の上流 fetch は AWS マネージド側で行われ、クライアント — ECR 間は通常の ECR API/DKR + S3 (layer 実体) のトラフィックしか流れない
- したがって VPC に **ECR API / ECR DKR / S3 Gateway** の 3 つを置けば、IGW/NAT なしでも cache miss → 上流 fetch → クライアントへの返却が成立するはず
- 上流が **ECR Public** なら認証不要なので Secrets Manager エンドポイントは不要
- Docker Hub などレートリミットや認証付きの上流の場合は Secrets Manager 周りで追加要件が出る可能性がある (本検証は ECR Public のみ)

## 検証環境

- VPC (private subnet only / IGW なし / NAT なし)
- VPC Endpoints
  - `com.amazonaws.<region>.ecr.api` (Interface)
  - `com.amazonaws.<region>.ecr.dkr` (Interface)
  - `com.amazonaws.<region>.s3` (Gateway, layer 実体取得用)
  - SSM 系 3 つ (`ssm`, `ssmmessages`, `ec2messages` — Session Manager 接続用、検証作業の都合)
- ECR Pull Through Cache rule: `ecr-public` prefix → `public.ecr.aws`
- EC2 (Amazon Linux 2023, Docker, IAM role に PTC 用権限)

## Approach 比較

| #  | Approach | 上流レジストリ | 認証 | 追加 Endpoints | 結果 |
|----|----------|----------------|------|----------------|------|
| 01 | VPC エンドポイントのみ + ECR Public PTC | `public.ecr.aws` | 不要 | なし (ECR API/DKR + S3 Gateway のみ) | **成功** |

> 02 以降のアイデア:
> - 02: Docker Hub PTC (Secrets Manager に上流クレデンシャル) — Secrets Manager 用 Interface Endpoint が要るか確認
> - 03: ECS タスクから PTC URL で pull (タスクロール経由 IAM)

## 結論 / 学び

**インターネット出口がネットワーク設計上存在しない VPC でも、ECR Pull Through Cache 経由なら初回 pull (cache miss) が成立する。** (2026-05-09 検証)

### 1. ネットワーク証拠

- IGW / NAT GW を **そもそも作っていない** (`describe-internet-gateways` / `describe-nat-gateways` が空配列で確認)
- ルートテーブルに `0.0.0.0/0` 経路が **存在しない** (local + S3 prefix list のみ)
- EC2 SG egress を VPC CIDR と S3 prefix list に絞り、`0.0.0.0/0` 全許可も **存在しない**
- 実機から `https://ec2.ap-northeast-1.amazonaws.com/` (AWS Public API) にも connect timeout — VPC エンドポイントを置いていない AWS API は到達不可
- それでも PTC URL での `docker pull` は成功する

### 2. cache miss の客観証拠 (busybox:1.36)

```
pull start         2026-05-09T09:44:07Z
repo createdAt     2026-05-09T09:44:07.246Z   ← +0.246s, pull window 内
pull finish        2026-05-09T09:44:09Z
duration           2.33s
digest             sha256:73aaf09... (= public.ecr.aws の公式 digest と一致)
```

→ **ECR がクライアント pull の瞬間に上流 `public.ecr.aws` から fetch して private repo を自動作成している**ことが時刻軸で確定。

### 3. 計測サマリ (n=3)

| image | 初回 cache miss | digest 一致 |
|-------|-----------------|-------------|
| alpine:3.20 (~3MB) | 1.68s | ✓ |
| busybox:1.36 (~4MB) | 2.33s (createdAt 一致確認済) | ✓ |
| nginx:1.27 (~70MB) | 5.50s | ✓ |

### 4. 構成上のキーポイント

- 必要 VPC Endpoint は **ECR API + ECR DKR + S3 Gateway** の 3 つのみ (本検証では Session Manager 用に SSM 系 3 つも追加)
- IAM policy に **`ecr:CreateRepository`** + **`ecr:BatchImportUpstreamImage`** が必須 (これが無いと `repository does not exist` / `Requested image not found` エラー)
- EC2 SG egress も VPC CIDR + S3 prefix list (`com.amazonaws.<region>.s3`) に絞ることで「物理的にも論理的にも外に出ない」状態を保てる

### 前回サンドボックス (push side) との比較

| | 20260412-ecr-push-without-internet | 20260509-ecr-pull-through-cache (本検証) |
|---|---|---|
| 解きたい問題 | private イメージを VPC に持ち込む | 公開イメージを pull する |
| インターネット要件 | なし (S3 中継で完結) | なし (PTC で完結) |
| 必要 Endpoint | ECR + S3 | ECR + S3 |
| 運用負荷 | アップロード or ビルド手順あり | `docker pull` 1 発 |

公開ベースイメージを使うだけなら **PTC のほうが圧倒的に楽**。private イメージや独自ビルドは前回サンドボックスのアプローチが必要。

## 関連リンク

- [Pulling an image with a pull through cache rule (AWS Docs)](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-working-pulling.html)
- [Creating a pull through cache rule (AWS Docs)](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-rule.html)
- [ECR interface VPC endpoints (AWS Docs)](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)
- 関連: `../20260412-ecr-push-without-internet/` (push 側)
