# =========================================================================
# GuardDuty: detector(import) + RUNTIME_MONITORING + ECS_FARGATE_AGENT_MANAGEMENT
#
# endpoint はこのモジュールでは作らない(create_data_endpoint=false)。
# 集約先 endpoint は central.tf 側で明示管理する(private DNS off)。
# 既存 module を流用: source は 02 本体の modules/。
#
# import が必要:
#   terraform import 'module.guardduty[0].aws_guardduty_detector.this' <detector-id>
# =========================================================================

module "guardduty" {
  count  = var.enable_guardduty ? 1 : 0
  source = "../../terraform/modules/guardduty-runtime-monitoring"

  name       = var.name
  region     = var.region
  vpc_id     = aws_vpc.central.id # endpoint は作らないので実質未使用
  vpc_cidr   = var.central_cidr   # 同上
  subnet_ids = [for s in aws_subnet.central : s.id]

  create_data_endpoint = false # ← endpoint は central.tf の手動管理に任せる
}
