# =========================================================================
# VPC Endpoints(NAT なしで image pull / logs を通すため)
#
# Gateway:
#   s3   … ECR レイヤ blob 取得(アプリ image + GuardDuty サイドカー image 両方)
# Interface:
#   ecr.api … ECR 認証/API(docker login, auth token)
#   ecr.dkr … Docker Registry(layer pull)
#   logs    … awslogs ドライバ
#
# guardduty-data endpoint は「監視の前提」なので guardduty.tf の別モジュール側で作る
# (この土台の endpoint とは責務を分ける)。
# =========================================================================

locals {
  interface_endpoints = {
    ecr_api = "ecr.api"
    ecr_dkr = "ecr.dkr"
    logs    = "logs"
  }
}

# interface endpoint 共通 SG(443 from VPC CIDR)
resource "aws_security_group" "endpoints" {
  name        = "${var.sandbox_name}-endpoints"
  description = "Interface endpoints (ECR/logs): 443 from VPC"
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

# ---- Interface endpoints ---------------------------------------------
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
