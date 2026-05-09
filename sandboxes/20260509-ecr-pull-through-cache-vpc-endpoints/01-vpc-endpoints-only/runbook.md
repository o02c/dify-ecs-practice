# 01-vpc-endpoints-only

ECR Pull Through Cache (PTC) を使い、**インターネット出口を一切持たない VPC** から `public.ecr.aws` 上のイメージを初回 pull できるかを確認する。

## 概要

```
[EC2 (private subnet, no IGW/NAT)]
        │ docker pull <acct>.dkr.ecr.<region>.amazonaws.com/ecr-public/docker/library/alpine:latest
        │
        ▼ ECR API/DKR Interface Endpoint + S3 Gateway Endpoint
   [ECR (AWS managed)]
        │  cache miss?
        │  ├─ Yes → 上流 fetch (ここはクライアントを経由しない)
        │  │       public.ecr.aws → ECR が私の private repo に書き戻し
        │  └─ No  → そのまま返却
        ▼
   クライアントへ image を返す
```

クライアント側に出口インターネットが無くても、**PTC の上流 fetch は ECR サービスが行うのでクライアント — ECR 間のトラフィックだけで完結する**…という仮説を検証する。

## 前提

- AWS credential が `AWS_PROFILE=terraform` で設定済み (リポジトリ既定)
- リージョン: ap-northeast-1
- 検証コストの目安: Interface Endpoint 5 つ × ~$0.014/h × 1AZ ≈ $0.07/h + EC2 t3.small + データ転送少々

## 手順

### 1. apply

```sh
cd terraform
AWS_PROFILE=terraform terraform init
AWS_PROFILE=terraform terraform plan
AWS_PROFILE=terraform terraform apply
```

apply 完了後 `terraform output` で `instance_id` `sample_pull_uri` を確認する。

### 2. EC2 に SSM Session Manager で接続

```sh
AWS_PROFILE=terraform aws ssm start-session --target $(terraform output -raw instance_id)
```

接続後、user-data で Docker が入っているはずなので確認する。

```sh
sudo systemctl status docker
sudo docker version
```

### 3. インターネット不可 (= VPC エンドポイント経由のみ) であることを確認

```sh
# IGW/NAT 経由の generic な外向きが落ちていることを確認
curl -m 5 https://example.com/  # → タイムアウトすればOK
curl -m 5 https://public.ecr.aws/  # → タイムアウトすればOK (上流に直接行けないことの確認)
```

ECR/S3 への DNS 解決は VPC エンドポイント経由で動くはず:

```sh
getent hosts $(terraform output -raw registry_uri)  # → 10.0.x.x が返れば private DNS が効いている
```

### 4. ECR にログイン

```sh
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-northeast-1
aws ecr get-login-password --region $REGION \
  | sudo docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
```

### 5. **初回 pull (cache miss) を観察**

```sh
time sudo docker pull ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ecr-public/docker/library/alpine:latest
```

期待:
- 成功する (= 仮説が正しい)
- 初回はやや時間がかかる (上流 fetch + キャッシュ書き込みのため)
- AWS コンソールで ECR private registry を見ると `ecr-public/docker/library/alpine` repo が**自動作成**されている

失敗する場合の典型:
- `repository does not exist` → IAM の `ecr:CreateRepository` 不足
- `Requested image not found` → `ecr:BatchImportUpstreamImage` 不足、または上流の image 名が間違い (Docker Hub official は `/library/` が必須、ECR Public はパスがそのまま `docker/library/...`)

### 6. 2 回目 pull (cache hit) を観察

```sh
sudo docker rmi ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ecr-public/docker/library/alpine:latest
time sudo docker pull ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ecr-public/docker/library/alpine:latest
```

期待: 2 回目以降は cache hit で速くなる。

### 7. 大きめのイメージで再現性確認 (任意)

```sh
# nginx
time sudo docker pull ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ecr-public/nginx/nginx:latest

# amazonlinux (~150MB)
time sudo docker pull ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ecr-public/amazonlinux/amazonlinux:latest
```

### 8. destroy

```sh
AWS_PROFILE=terraform terraform destroy
```

> 注: PTC で自動作成された `ecr-public/...` repos は terraform 管理外 (apply 後に作られる)。`force_delete = true` を付けていないので、不要なら手動で `aws ecr delete-repository --repository-name ecr-public/docker/library/alpine --force` する。

## 結果 (2026-05-09)

**仮説どおり成立**。クライアント側からインターネット出口が**ネットワーク設計レベルで存在しない**状態でも PTC 経由で初回 pull できた。

### A. 「インターネット出口が無い」のネットワーク証拠

VPC レベルで物理的に経路が無いことを 4 段階で確認:

```
=== Internet Gateway ===
[]

=== NAT Gateway ===
[]

=== Route Table Routes ===
[ { "DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local", "State": "active" } ]
[ { "DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local", "State": "active" },
  { "DestinationPrefixListId": "pl-61a54008",  // S3 prefix list
    "GatewayId": "vpce-05d431ec22ec1209c",     // S3 Gateway Endpoint
    "State": "active" } ]

=== EC2 Security Group Egress ===
- VPC internal (10.0.0.0/16) all proto    # → Interface Endpoints のみ
- TCP 443 to S3 prefix list (pl-61a54008) # → S3 Gateway Endpoint のみ
# 0.0.0.0/0 は egress に存在しない
```

**ポイント**:
- IGW / NAT GW が **そもそも存在しない**
- ルートテーブルに `0.0.0.0/0` への route が **無い** (local + S3 prefix list だけ)
- EC2 SG egress も VPC CIDR + S3 prefix list に絞り、`0.0.0.0/0` 全許可は **無い**
- どの層を通っても VPC の外には出られない構成

実機からの egress smoke test (EC2 内):

| 宛先 | 結果 |
|------|------|
| `https://example.com` | curl timeout (rc=28, 5.00s) |
| `https://public.ecr.aws` | curl timeout (rc=28, 5.00s) |
| `https://ec2.ap-northeast-1.amazonaws.com` | `Connect timeout on endpoint URL` (= AWS の EC2 public endpoint にすら到達できない) |
| ECR Interface Endpoint (`10.0.1.173:443`) | reachable ✓ |

### B. 「初回 pull = cache miss」のタイムスタンプ一致証拠

clean な検証として **busybox:1.36** を pull した結果:

```
PULL_STARTED_AT  = 2026-05-09T09:44:07Z          ← pull 開始 (date -u)
repo createdAt   = 2026-05-09T09:44:07.246Z      ← ECR が repo を自動作成した瞬間 (+0.246s)
PULL_FINISHED_AT = 2026-05-09T09:44:09Z          ← pull 完了 (date -u)
BUSYBOX_FIRST_PULL_DURATION = 2.33s
digest = sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
```

`createdAt` が pull 開始から +0.246s と完全に pull ウィンドウ内に入っている → **PTC repo は本当に pull のタイミングで自動作成された** = cache miss であることが客観的に確定。

### C. 計測サマリ (n=3 image)

| image | 種類 | 初回 (cache miss) | digest 一致 (公開と) |
|-------|------|-------------------|----------------------|
| `ecr-public/docker/library/alpine:3.20` (~3MB) | small | 1.68s | ✓ `sha256:d9e853...` |
| `ecr-public/docker/library/busybox:1.36` (~4MB) | small + 自動作成タイムスタンプ取得済 | 2.33s | ✓ `sha256:73aaf09...` |
| `ecr-public/nginx/nginx:1.27` (~70MB) | medium | 5.50s | ✓ `sha256:df80ec...` |

cache hit (alpine:3.20 再 pull): 1.01s

### D. 仮説が成立した根拠 (まとめ)

1. **クライアントは AWS パブリックエンドポイントにすら到達できない** (`ec2.ap-northeast-1.amazonaws.com` への curl が connect timeout)
2. ルートと SG の両方に `0.0.0.0/0` 経路が存在しない (= 設計レベルで egress 無し)
3. それでも PTC URL での pull は成功し、image digest は **`public.ecr.aws` の公式 digest と完全一致**
4. private repo は pull 開始から +0.246s の瞬間に自動作成 (createdAt が pull window 内)
5. → 上流 `public.ecr.aws` への fetch は **ECR サービス内部で実行されている** ことが論理的に確定

### E. 引っかかったポイント / メモ

- IAM 最小権限の落とし穴: 通常の pull に必要な権限とは別に PTC では `ecr:CreateRepository` + `ecr:BatchImportUpstreamImage` が必要 (これが無いと `repository does not exist` / `Requested image not found` の一見 image 名の typo に見えるエラーになる)。本検証では運用調査用に `ecr:DescribeImages` も足したが pull 自体には不要。
- EC2 内に `ec2:Describe*` 権限を一切付けていないが、それ以前にネットワーク的に AWS EC2 API に到達できないため CLI 自体が timeout する。意図せず「網閉鎖の追加証拠」になった。
- Pull through cache は repo 自動作成型なので `terraform destroy` の前にキャッシュされた repo を消す必要がある (TF 管理外のため)。

## 観察ポイント

- 初回 pull の latency (上流 fetch 込み) と 2 回目 pull の latency 比
- ECR コンソール上で repo が自動作成されたか
- 上流 fetch は ECR サービス側で行われるため、クライアント側 SG の egress を絞っても (= `0.0.0.0/0` を消しても) 動くはず — 余裕があれば確認
- `private_dns_enabled = true` を切るとどう壊れるか (PTC 起因か Endpoint 起因かの切り分け)
