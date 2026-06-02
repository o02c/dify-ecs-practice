# 02-alb-2az

CloudFront VPC Origins を **ALB origin + 2 AZ private subnet** で組んだ最小構成。01-ec2-minimal の EC2 直 origin 版に対して、本番運用想定のレイヤを反映。

## 概要

- VPC + IGW (attach のみ) + private subnet × 2 (AZ a / b、`apne1-az3` 除く) + ALB SG (CF service SG から ingress) + EC2 SG (ALB SG から ingress) + ALB (internal, 2 AZ) + target group + listener + EC2 t4g.nano (Python http.server) + CloudFront VPC Origin (ALB ARN を指す) + Distribution の **16 resource**
- viewer cert は CloudFront default cert、ingress は service-managed SG 経由 (01 と同方針)
- 検証 toggle: `vpc_bpa_mode` / `enable_vpc_bpa_exclusion_subnet_a` / `enable_vpc_bpa_exclusion_subnet_b` / `use_custom_nacl` + NACL allow rule 4 toggle

## ENI 配置 (実機確認)

| ENI                         | Subnet               | Type                | 用途                                |
| --------------------------- | -------------------- | ------------------- | ----------------------------------- |
| `eni-...298196` (10.0.1.64) | subnet a             | interface           | ALB ENI (AZ a)                      |
| `eni-...86145` (10.0.1.188) | subnet a             | interface           | EC2 (target)                        |
| `eni-...448522` (10.0.1.65) | subnet a             | **cloudfront_managed** | CloudFront VPC Origin 用 ENI (AZ a) |
| `eni-...82bf4` (10.0.2.144) | subnet b             | interface           | ALB ENI (AZ b)                      |
| `eni-...2b884b` (10.0.2.109) | subnet b             | **cloudfront_managed** | CloudFront VPC Origin 用 ENI (AZ b) |

CloudFront 管理 ENI は **両 AZ にそれぞれ 1 個ずつ自動配置**される。

## 手順

```sh
export AWS_PROFILE=terraform
cd terraform
terraform init
terraform plan
terraform apply
```

apply 所要時間 実測:

| resource group                                   | 時間   |
| ------------------------------------------------ | ------ |
| VPC / IGW / 2 subnet / SG / SG rule (各 < 5 秒)  | 計 5 秒以内 |
| EC2 + target_group_attachment                    | 13 秒  |
| ALB (internal, 2 AZ)                             | **3m11s** |
| CloudFront VPC Origin                            | **9m10s** |
| CloudFront Distribution                          | **2m48s** |

合計 ~15 分。`terraform output -raw distribution_url` の URL に curl で 200 OK が想定。

## 結果

### BPA テスト

| BPA mode             | exclusion (subnet a) | exclusion (subnet b) | curl 結果           |
| -------------------- | -------------------- | -------------------- | ------------------- |
| off                  | -                    | -                    | 200 (baseline, 5/5) |
| block-ingress        | なし                 | なし                 | 504 (4/4) |
| block-ingress        | **subnet a のみ**    | -                    | **200 (6/6)**       |
| block-ingress        | -                    | **subnet b のみ**    | **200 (6/6)**       |
| block-ingress        | ✓                    | ✓                    | 200 (4/4)           |

**発見**: 2 AZ ALB 構成では **片方の subnet だけ exclusion すれば疎通成立**。CloudFront が許可された CF ENI を選択して使う模様 (failover 的挙動)。
ただし HA 観点で **両 subnet exclusion が正解** (片 AZ 障害時に through-traffic を維持するため)。

### NACL テスト (両 subnet に同一 custom NACL を associate)

| # | ingress tcp 80 | ingress tcp 1024-65535 | egress tcp 80 | egress tcp 1024-65535 | curl |
| -- | -- | -- | -- | -- | -- |
| N1 | - | - | - | - | 504 (3/3) |
| N2 | - | **✓** | - | **✓** | **200 (4/4)** |

01-ec2-minimal と **同じ最小 allow set** (ingress/egress 共に ephemeral だけ)。ALB origin / 2 AZ でも変わらず。

## 考察

### ALB 経由特有の知見

- ALB SG / EC2 SG の **2 段構成**: ALB SG ingress は CloudFront service-managed SG、EC2 SG ingress は ALB SG → 自分の Distribution → 自分の ALB → 自分の EC2 の path のみ通る
- ALB は internal 用途でも **2 AZ subnet 必須**。EC2 origin の 1 subnet 最小構成より大きい
- CloudFront 管理 ENI は **AZ ごとに 1 個** 自動配置される (合計 2 個)
- BPA exclusion は **片 subnet で疎通成立** だが HA 観点で両 subnet 推奨

### 01-ec2-minimal と共通の知見 (再確認)

- VPC BPA: `block-ingress` / `block-bidirectional` 両モードで疎通止まる、exclusion が必須
- NACL: docs と挙動が食い違い、最小 allow = ingress/egress 共に ephemeral (1024-65535)、origin port (80) は不要
- service-managed SG (`CloudFront-VPCOrigins-Service-SG`) を `data` + `depends_on` で参照する pattern は ALB origin でも同じく機能

## メモ

- `aws_lb.this.security_groups` で ALB に SG attach。NLB は SG attach option ありの構成のみ VPC Origin 利用可
- ALB target group health check は EC2 SG (ingress from ALB SG) があれば通る。今回は ALB → EC2 80 番で healthcheck 成立
- `aws_vpc_security_group_egress_rule.alb_to_ec2` で ALB から EC2 への egress を明示。SG egress は default で 0.0.0.0/0 全 allow だが、新しい `aws_security_group` は egress rule なし状態で作られる挙動を考慮
