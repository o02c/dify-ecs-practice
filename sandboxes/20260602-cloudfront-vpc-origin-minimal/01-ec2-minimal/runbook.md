# 01-ec2-minimal

CloudFront VPC Origins の疎通確認ができるギリギリの最小構成 (8 resource)。EC2 t4g.nano に Python `http.server` を立てて origin にする。

## 概要

- VPC + IGW (attach のみ、route table には載せない) + private subnet + EC2 + SG + SG ingress rule + CloudFront VPC Origin + CloudFront Distribution
- viewer cert は CloudFront default cert (`*.cloudfront.net`) で済ませ ACM / Route53 不要
- SG ingress は CloudFront managed prefix list (`pl-58a04531` / `com.amazonaws.global.cloudfront.origin-facing`) のみ
- `var.vpc_bpa_mode` で AWS アカウント単位の **VPC Block Public Access** を切替 (`off` / `block-bidirectional` / `block-ingress`)
- `var.enable_vpc_bpa_exclusion = true` で本 sandbox の VPC を BPA から除外 (`allow-bidirectional`)

## 前提

- `AWS_PROFILE=terraform` でこの sandbox を実行
- Region: `ap-northeast-1` (VPC Origins 対応、`apne1-az3` を除外する data source で AZ 選択)
- 必要な IAM 権限: VPC / EC2 / CloudFront / (BPA 試すなら) `ec2:ModifyVpcBlockPublicAccessOptions` + `ec2:CreateVpcBlockPublicAccessExclusion`

## 手順

### 1. apply (BPA off)

```sh
export AWS_PROFILE=terraform
cd terraform
terraform init
terraform plan
terraform apply
```

**実測 apply 所要時間 (8 resource)**: 約 12 分。内訳:

| resource                     | 時間   |
| ---------------------------- | ------ |
| VPC / IGW / subnet / SG / SG ingress rule | < 5 秒/個 |
| EC2 (t4g.nano, AL2023)       | 13 秒  |
| CloudFront VPC Origin        | **9m9s** |
| CloudFront Distribution      | **3m9s** |

outputs に `distribution_url` が出る。

### 2. 疎通確認

```sh
URL=$(terraform output -raw distribution_url)
curl -sS "$URL"
# => Hello from VPC Origin (private) at 10.0.1.X
```

**実測**: HTTP 200、`x-cache: Miss from cloudfront`、`x-amz-cf-pop: SFO53-P9` (PriceClass_100 で日本 edge 無し)。

### 3. BPA 各モードの挙動を検証

```sh
# block-ingress に切替 (約 3 min)
terraform apply -var vpc_bpa_mode=block-ingress
curl -sS --max-time 35 "$URL"
# => 504 Gateway Timeout

# block-bidirectional に切替
terraform apply -var vpc_bpa_mode=block-bidirectional
curl -sS --max-time 35 "$URL"
# => 504 Gateway Timeout

# 本 VPC を exclusion に追加 (BPA mode は維持)
terraform apply -var vpc_bpa_mode=block-bidirectional -var enable_vpc_bpa_exclusion=true
curl -sS "$URL"
# => Hello from VPC Origin (private) at 10.0.1.X (200)
```

BPA 状態の確認:

```sh
aws ec2 describe-vpc-block-public-access-options --region ap-northeast-1
aws ec2 describe-vpc-block-public-access-exclusions --region ap-northeast-1
```

**確認後は必ず off に戻す** (アカウント + region 単位のグローバル設定なので他 VPC にも影響):

```sh
terraform apply -var vpc_bpa_mode=off -var enable_vpc_bpa_exclusion=false
# or
terraform destroy
```

### 4. destroy

```sh
terraform destroy
```

実測 約 17 分:

- CloudFront Distribution: disable → delete で 15 分前後
- CloudFront VPC Origin: 数分
- VPC BPA options / exclusion: 各 30〜60 秒
- VPC / EC2 / SG: 即時

## 結果

### 疎通マトリクス (実測)

#### BPA 系

| BPA mode             | exclusion (mode = allow-bidirectional) | curl 結果 (3 回)             |
| -------------------- | -------------------------------------- | ---------------------------- |
| off                  | -                                      | HTTP 200, ~0.6s              |
| block-bidirectional  | なし                                   | HTTP 504, 30s timeout x3     |
| block-ingress        | なし                                   | HTTP 504, 30s timeout x3     |
| block-ingress        | VPC 単位                               | HTTP 200, ~0.6s              |
| block-ingress        | **subnet 単位 (origin subnet のみ)**   | HTTP 200, ~0.6s              |

AWS サポート公式回答どおり、**origin を置く subnet 単位の exclusion だけで十分**。VPC 全体を許可する必要はない (最小権限的にも subnet 単位推奨)。

#### NACL 系 (Service-managed SG ingress + origin subnet に custom NACL)

| #  | ingress tcp 80 | ingress tcp 1024-65535 | egress tcp 80 | egress tcp 1024-65535 | curl  |
| -- | -------------- | ---------------------- | ------------- | --------------------- | ----- |
| A  | -              | -                      | -             | -                     | 504   |
| B  | ✓              | -                      | -             | -                     | 504   |
| D  | ✓              | -                      | -             | ✓                     | 504   |
| I  | -              | ✓                      | -             | -                     | 504   |
| J  | -              | -                      | -             | ✓                     | 504   |
| **H** | -           | **✓**                  | -             | **✓**                 | **200** ← 最小 |
| F  | ✓              | ✓                      | -             | ✓                     | 200   |
| E  | ✓              | ✓                      | ✓             | ✓                     | 200   |

**最小 NACL allow set = `ingress tcp dst 1024-65535` + `egress tcp dst 1024-65535` のみ**。origin port (80, または 443) は ingress / egress どちらにも不要。

考察: CloudFront 管理 ENI と EC2 ENI は同 subnet に lives している (実機の `describe-network-interfaces` で確認)。
- subnet 内 hop (CF ENI ↔ EC2 ENI、dst port 80) の packet は NACL に当たらない
- NACL に当たるのは CF ENI ↔ 外部 CloudFront edge plane の internal protocol で、両側 ephemeral port を使う模様
- そのため `ingress tcp 80` / `egress tcp 80` ともに **不要**、両側 ephemeral だけが必須

AWS Docs の主張「VPC origins ... NACLs: Subnet-level allow and deny rules are not evaluated for this traffic.」は **実機と矛盾** (deny-all NACL で 504 になる)。docs の意図する scope (CF ENI ↔ EC2 ENI 間に限れば確かに評価されない) と read できなくはないが、subnet 単位で見れば NACL は明確に評価されている。

### 切り分けに使ったコマンド

```sh
# BPA 状態
aws ec2 describe-vpc-block-public-access-options --region ap-northeast-1

# CloudFront VPC Origin の deploy 状態
aws cloudfront list-vpc-origins --region us-east-1
```

## 考察

### 良い点

- **8 resource で済む**。NAT GW / public subnet / EIP / ACM / Route53 すべて不要
- ACM / Route53 すら省けるので「private な配信元を public な見た目で公開」を試すコストが極小 (検証 40 分で $0.05 未満)
- `aws_vpc_security_group_ingress_rule` + `prefix_list_id` の組合せで CloudFront 側 IP を意識せず ingress 制御できる
- VPC BPA + exclusion の組合せが Terraform 1 stack 内で完結する

### 悪い点 / 制約

- **VPC Origin の作成だけで 9 分超**。短サイクルで触り直すには向かない (destroy も含めると 1 cycle 30 分弱)
- **VPC BPA の `block-ingress` / `block-bidirectional` どちらでも VPC Origin の inbound traffic は止まる**。仮説の「IGW 経由しないから素通り」は外れ
  - AWS サポート公式回答: **CF → VPC Origin の実トラフィックは IGW を経由しない**。にも関わらず BPA で止まる理由は「**内部処理のために該当 subnet で BPA 許可 (exclusion) が必要**」 (2026-06 時点で公式 docs に未掲載)
  - 実運用で BPA を ON にする場合は VPC Origin を置く subnet (または VPC) を必ず `allow-bidirectional` / `allow-egress` exclusion に入れる
- PriceClass_100 だと日本 edge 経由にならない。本番運用なら PriceClass_All か `_200` を選ぶ

## メモ

- `aws_cloudfront_distribution.origin.domain_name` は `vpc_origin_config` 利用時も API 必須なので `placeholder.invalid` を入れている。CloudFront は実際の routing には使わない
- `aws_cloudfront_vpc_origin.vpc_origin_endpoint_config.origin_ssl_protocols` は `origin_protocol_policy = "http-only"` でも API 必須
- SG description には `>` 文字が使えない (`a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*` のみ)。`->` を `to` に書き換える hit あり
- EC2 user_data は root 実行なので Python `http.server` を 80 番に直接 bind できる。systemd unit にしておくと user_data 終了後も生存
- `terraform destroy` 中に `aws_vpc_block_public_access_options` を delete すると **自動で `off` に戻る** (provider 仕様)。アカウント設定が中途半端な状態で残らない
