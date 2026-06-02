# CloudFront VPC Origins 最小構成

> 検証日: 2026-06-02
> Obsidian: [[ノートへのリンク]]

## 背景 / 課題

CloudFront **VPC Origins** (2024-11 GA) は、private subnet にいる ALB / NLB / EC2 を public IP / ALB 公開なしで CloudFront から直接配信できる機能。本番投入前に「**疎通確認できるギリギリの最小構成**」を掴んでおきたい。

合わせて 2024-11 に出た **VPC Block Public Access (BPA)** を on にしても VPC Origin が引き続き通ることも検証する (IGW を経由しないので理論上は通るはず)。

## 仮説

- VPC Origins の最小依存は **VPC + IGW (attach のみ) + private subnet + EC2 + SG + VPC Origin + Distribution** の 7 リソース
  - IGW は AWS Docs の prerequisite で必須だが route table には載せなくて良い (= 実質 private のまま)
  - NAT GW / public subnet / EIP / ACM / Route53 すべて不要
- SG ingress は **CloudFront managed prefix list** (`com.amazonaws.global.cloudfront.origin-facing`) から許可するだけで CloudFront → EC2 80 番が通る
- viewer cert は **CloudFront default certificate** (`*.cloudfront.net`) で済むので ACM 不要
- **VPC BPA が `block-bidirectional` でも VPC Origin の疎通は維持される** (IGW を経由しない service-managed ENI 経由のため) ← **検証で外れた**

## 検証環境

- Region: `ap-northeast-1` (VPC Origins サポート、`apne1-az3` 以外の AZ を使う)
- AWS Profile: `terraform`
- Origin: EC2 t4g.nano + AL2023 + Python `http.server` (systemd unit)
- 想定コスト: 30 分以内で $0.01 未満 (t4g.nano + CloudFront リクエスト数件)

## Approach 比較

| #   | Approach     | 概要                                                                                                              | リソース数 | コスト                            | 結果                                                                                                  |
| --- | ------------ | ----------------------------------------------------------------------------------------------------------------- | ---------- | --------------------------------- | ----------------------------------------------------------------------------------------------------- |
| 01  | ec2-minimal  | VPC + IGW (attach のみ) + 1 subnet + SG + EC2 + VPC Origin + Distribution の超最小                                | 8          | 検証 1 セット 約 40 min で $0.05 未満 | 最小構成で 200 OK 成立。BPA は **モードに関係なく VPC Origin もブロック**、subnet 単位 exclusion で疎通復活。NACL は ingress/egress 共に ephemeral だけが最小 |
| 02  | alb-2az      | VPC + IGW + 2 AZ subnet + ALB SG + EC2 SG + EC2 + ALB + TG + listener + VPC Origin + Distribution の本番想定構成 | 16         | 検証 1 セット 約 45 min で $0.10 未満 | CloudFront 管理 ENI が **両 AZ subnet にそれぞれ 1 個ずつ配置**。BPA exclusion は **片 subnet だけで疎通成立** (CF が許可 ENI を選択)、ただし HA 観点で両 subnet 推奨。NACL 最小 set は 01 と同じく ingress/egress ephemeral のみ |

詳細は各 approach の `runbook.md` を参照。

## 結論 / 学び

- **最小 7 リソース + CloudFront default cert + managed prefix list** で疎通成立 (apply 約 12 min、CloudFront VPC Origin だけで 9m9s、Distribution は 3m9s)
- 仮説「BPA on でも IGW 非経由だから VPC Origin は通る」は **外れ**:
  - `block-bidirectional` でも `block-ingress` でも 504 Gateway Timeout
  - 後に AWS サポートに確認した公式回答: **CF → VPC Origin の実トラフィックは IGW を経由しない**。にも関わらず BPA で止まる理由は「**内部処理のために該当 subnet で BPA 許可が必要**」(2026-06 時点で docs に明記されていない仕様)
- **回避策は `aws_vpc_block_public_access_exclusion`** で origin を置く subnet を `allow-bidirectional` 例外指定
  - BPA on (`block-ingress`) + subnet 単位 exclusion で疎通復活 (HTTP 200、~0.6s) — VPC 全体を許可する必要はない (実機検証済)
  - 「アカウント全体に BPA を ON、VPC Origin の origin subnet だけ exclusion」が最小権限的に正解
- VPC Origin の作成・更新は **数分〜10 分単位** で遅い。短サイクルの iteration には向かない (terraform apply 1 回 12 分、destroy も Distribution disable で 20 分弱)
- Origin SG ingress は **CloudFront service-managed SG (`CloudFront-VPCOrigins-Service-SG`)** を data + `depends_on` で引き、`referenced_security_group_id` で絞ると prefix list よりさらに最小権限 (自分の Distribution からのみ通す)
- **NACL は実機では VPC Origin traffic にも評価される** (docs の主張と矛盾)。**最小 allow set は ingress/egress 共に ephemeral (1024-65535) の TCP**、origin port (80/443) は不要。CF 管理 ENI と origin (EC2 / ALB) ENI が同 subnet にいるため request の path は subnet 内で閉じ、NACL に当たるのは CF ENI ↔ 外部 CF edge plane の internal protocol だけ、と説明できる挙動
- ALB 2 AZ 構成 (02-alb-2az) では CF 管理 ENI が **両 AZ subnet にそれぞれ 1 個ずつ自動配置**される。BPA exclusion は片方の subnet だけでも疎通成立 (CF が許可された ENI を選択する挙動)、ただし HA 観点で **両 subnet exclusion を推奨**

## 関連リンク

- [Restrict access with VPC origins (CloudFront Dev Guide)](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)
- [Block public access to VPCs and subnets (VPC User Guide)](https://docs.aws.amazon.com/vpc/latest/userguide/security-vpc-bpa.html)
- [CloudFront managed prefix list](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html#managed-prefix-list)
