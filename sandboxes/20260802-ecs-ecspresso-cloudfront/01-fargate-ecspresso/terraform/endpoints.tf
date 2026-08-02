# =========================================================================
# VPC Endpoints (NAT なしで Fargate pull / CodeBuild の全操作を通すため)
#
# Gateway:
#   s3 … ECR レイヤ blob 取得 + deploy.zip 取得 + frontend sync + tfstate 読取 (無料)
#
# Interface (var.interface_endpoint_services で定義。各エンドポイントの用途は値のコメント参照):
#   必要性は disable_interface_endpoints で個別に外して実機検証できる。
# =========================================================================

variable "interface_endpoint_services" {
  description = "作成する interface endpoint (key => AWS service short name)。用途は下記コメント参照。"
  type        = map(string)

  # 実機で必要性を切り分けた結果 (v2.8.4, 2026-08-02) を反映した最小セット。
  # 検証詳細は runbook / README の「VPC Endpoint 必要性の実機切り分け」参照。
  default = {
    # --- 必須: Fargate ランタイム pull + CodeBuild image push (private/NAT なし) ---
    ecr_api = "ecr.api" # ECR 認証/API (docker login, auth token)
    ecr_dkr = "ecr.dkr" # Docker Registry (layer pull / push)
    logs    = "logs"    # awslogs ドライバ (Fargate) + CodeBuild build log
    # --- 必須: CodeBuild 上の ecspresso deploy の ECS control-plane ---
    ecs = "ecs" # taskdef 登録 / service 更新 / deploy 完了待ち(外すと即 FAILED)
    # --- 任意(外すと deploy 完了だが ~90s タイムアウト遅延): status 表示用 ---
    appautoscaling = "application-autoscaling" # DescribeScalableTargets (autoscaling 未設定でも叩く)
    # --- 除外: v2.8.4 では未使用と実証。必要になれば再追加できる ---
    # sts = "sts"                  # deploy 中 GetCallerIdentity を呼ばず、外しても影響なし
    # elb = "elasticloadbalancing" # deploy 完了待ちは ecs:ListServiceDeployments 経由。ELB API は未呼出
  }
}

variable "disable_interface_endpoints" {
  description = "一時的に外す interface endpoint の key 集合 (必要性の実機検証用)。例: [\"sts\",\"appautoscaling\"]"
  type        = set(string)
  default     = []
}

locals {
  interface_endpoints = {
    for k, svc in var.interface_endpoint_services : k => svc
    if !contains(var.disable_interface_endpoints, k)
  }
}

# ---- Interface endpoint 共通 SG (全 interface endpoint が使う) ---------
# description は immutable で、変更すると SG 全体が replace (同名衝突で apply 失敗リスク)
# になるため既存の文言のまま維持する。実体は ecr/logs/ecs/elb/sts/appautoscaling 共用。
resource "aws_security_group" "endpoints" {
  name        = "${var.sandbox_name}-endpoints"
  description = "Interface endpoints (ECR/logs) : 443 from VPC"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from VPC CIDR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = aws_vpc.this.cidr_block
}

# 明示 egress (SG 再作成時に AWS default allow-all に依存しないため)
resource "aws_vpc_security_group_egress_rule" "endpoints_all" {
  security_group_id = aws_security_group.endpoints.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- Gateway endpoint: S3 --------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.sandbox_name}-s3" }
}

# ---- Interface endpoints (for_each) ----------------------------------
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.sandbox_name}-${each.key}" }
}

# 個別 resource から for_each へ state を引き継ぐ (destroy/recreate 回避)
moved {
  from = aws_vpc_endpoint.ecr_api
  to   = aws_vpc_endpoint.interface["ecr_api"]
}
moved {
  from = aws_vpc_endpoint.ecr_dkr
  to   = aws_vpc_endpoint.interface["ecr_dkr"]
}
moved {
  from = aws_vpc_endpoint.logs
  to   = aws_vpc_endpoint.interface["logs"]
}
moved {
  from = aws_vpc_endpoint.ecs
  to   = aws_vpc_endpoint.interface["ecs"]
}
moved {
  from = aws_vpc_endpoint.elb
  to   = aws_vpc_endpoint.interface["elb"]
}
moved {
  from = aws_vpc_endpoint.sts
  to   = aws_vpc_endpoint.interface["sts"]
}
moved {
  from = aws_vpc_endpoint.appautoscaling
  to   = aws_vpc_endpoint.interface["appautoscaling"]
}
