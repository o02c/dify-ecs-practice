# =========================================================================
# 監視モジュール呼び出し(土台の VPC/subnet/CIDR を注入するだけ)
#
# enable_guardduty=false にすると監視を一切作らない(有効化前の素の Fargate)。
# import が必要:
#   terraform import 'module.guardduty[0].aws_guardduty_detector.this' <detector-id>
# =========================================================================

module "guardduty" {
  count  = var.enable_guardduty ? 1 : 0
  source = "./modules/guardduty-runtime-monitoring"

  name       = var.sandbox_name
  region     = var.region
  vpc_id     = aws_vpc.this.id
  vpc_cidr   = aws_vpc.this.cidr_block
  subnet_ids = [for s in aws_subnet.private : s.id]

  create_data_endpoint = var.create_guardduty_data_endpoint
}
