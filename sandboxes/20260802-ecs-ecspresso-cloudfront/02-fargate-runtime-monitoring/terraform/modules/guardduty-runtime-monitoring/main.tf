# =========================================================================
# GuardDuty Runtime Monitoring (ECS Fargate) 監視モジュール
#
# 作るもの:
#   1. detector(enable=true)          … account/region singleton。既存を import して管理。
#   2. RUNTIME_MONITORING feature       … 追加設定 ECS_FARGATE_AGENT_MANAGEMENT=ENABLED
#   3. guardduty-data interface endpoint + SG … private subnet からサイドカーのテレメトリ送信路
#
# 挙動(A=単一アカウント本モジュール / B=管理アカウント一括自動有効 で同一):
#   feature が ENABLED になった時点で、条件を満たす「新規起動」Fargate タスクへ
#   AWS 管理のサイドカーが自動注入される。per-task 操作は不要。
#   既存タスクは immutable なので relaunch / forceNewDeployment が要る。
# =========================================================================

# ---- detector(既存を import して enable 管理)-------------------------
# import: terraform import 'module.guardduty[0].aws_guardduty_detector.this' <detector-id>
# destroy 時は enable=false に戻る(元の DISABLED 状態へ復帰 = 可逆)。
resource "aws_guardduty_detector" "this" {
  enable = true
}

# ---- RUNTIME_MONITORING + ECS Fargate agent 自動管理 ------------------
resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  # ECS Fargate のサイドカー自動注入。EC2/EKS はこの検証の対象外なので触らない
  # (未指定の追加設定は現状維持)。
  additional_configuration {
    name   = "ECS_FARGATE_AGENT_MANAGEMENT"
    status = "ENABLED"
  }
}

# ---- guardduty-data endpoint + SG ------------------------------------
# private subnet(NAT なし)ではサイドカーがここを通れないとテレメトリを送れず
# coverage が UNHEALTHY(VPC_ISSUE 等)になる。これが「有効にならない」本番症状の第一候補。
resource "aws_security_group" "guardduty_data" {
  count = var.create_data_endpoint ? 1 : 0

  name        = "${var.name}-guardduty-data"
  description = "GuardDuty runtime monitoring data endpoint: 443 from VPC"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-guardduty-data" }
}

resource "aws_vpc_security_group_ingress_rule" "guardduty_data_https" {
  count = var.create_data_endpoint ? 1 : 0

  security_group_id = aws_security_group.guardduty_data[0].id
  description       = "HTTPS from VPC CIDR (task ENI to guardduty-data)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "guardduty_data_all" {
  count = var.create_data_endpoint ? 1 : 0

  security_group_id = aws_security_group.guardduty_data[0].id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# private DNS を有効にするため、VPC 側で enableDnsSupport/enableDnsHostnames が
# 両方 true である必要がある(呼び出し側 VPC で担保済み)。
# endpoint policy は single-account では default(full access)で足りる。
# shared-VPC/org 共有時のみ aws:PrincipalOrgID ベースの制限が要る(runbook 参照)。
resource "aws_vpc_endpoint" "guardduty_data" {
  count = var.create_data_endpoint ? 1 : 0

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.guardduty-data"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.guardduty_data[0].id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-guardduty-data" }
}
