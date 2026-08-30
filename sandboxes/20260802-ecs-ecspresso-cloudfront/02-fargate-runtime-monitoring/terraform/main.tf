# =========================================================================
# GuardDuty ECS Fargate Runtime Monitoring を「素の private Fargate」で観測する土台
#
# 01(ecspresso + CloudFront)から監視観測に不要な層を全て削った最小版:
#   - CloudFront / ALB / VPC Origin / S3 frontend / OAC / CodeBuild / ecspresso: 無し
#   - 残すのは「private subnet(NAT なし)で 1 本だけ Fargate タスクを常駐させる」土台
#
# GuardDuty coverage は「タスクが起きていれば」付くので LB は不要。
# 監視の有効化(detector feature)と guardduty-data endpoint は guardduty.tf の
# 別モジュール(modules/guardduty-runtime-monitoring)に隔離する。
# =========================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

# ---- VPC / subnet / route --------------------------------------------
# private DNS で guardduty-data / ECR endpoint を解決させるため DNS 属性は両方 true。
# (これが false だと guardduty-data endpoint の private DNS 有効化に失敗する)
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.sandbox_name }
}

# Fargate 配置 + interface endpoint の HA 用に 2 AZ private subnet。
# NAT / IGW は張らない(= 完全 private。到達は VPC endpoint 経由のみ)。
resource "aws_subnet" "private" {
  for_each = toset(["a", "b"])

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.key == "a" ? "10.0.1.0/24" : "10.0.2.0/24"
  availability_zone = each.key == "a" ? data.aws_availability_zones.available.names[0] : data.aws_availability_zones.available.names[1]

  tags = { Name = "${var.sandbox_name}-private-${each.key}" }
}

# S3 Gateway Endpoint の route 注入先(local route のみ / NAT なし)。
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.sandbox_name}-private" }
}

# for_each のキーは静的(["a","b"])にする。resource map をそのまま for_each に
# 渡すと未 apply 状態(import 前)でキー不定となり import がブロックされるため。
resource "aws_route_table_association" "private" {
  for_each = toset(["a", "b"])

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}

# ---- task SG ----------------------------------------------------------
# ingress 不要(LB なし・外から叩かない)。egress は 443 全許可で
#   - ECR(ecr.api/ecr.dkr)+ S3(gw)  … アプリ image + GuardDuty サイドカー image の pull
#   - logs                          … awslogs
#   - guardduty-data                … サイドカーのテレメトリ送信
# を全て VPC endpoint 経由(NAT なし)で通す。
resource "aws_security_group" "task" {
  name        = "${var.sandbox_name}-task"
  description = "Fargate task: egress 443 to VPC endpoints (ECR/S3/logs/guardduty-data)"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.sandbox_name}-task" }
}

resource "aws_vpc_security_group_egress_rule" "task_egress_all" {
  security_group_id = aws_security_group.task.id
  description       = "all egress to VPC endpoints (443) and S3 prefix-list"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
