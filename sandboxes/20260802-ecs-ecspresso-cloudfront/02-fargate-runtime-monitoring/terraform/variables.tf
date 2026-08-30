variable "region" {
  description = "AWS region。GuardDuty Runtime Monitoring と guardduty-data endpoint がある Region。"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子。"
  type        = string
  default     = "ecs-gd-runtime"
}

# ---- GuardDuty 有効化のトグル -------------------------------------------
# false にすると監視モジュール(detector feature + guardduty-data endpoint)を作らず、
# 「有効化前 / 素の Fargate」の状態で土台だけ apply できる。UNHEALTHY 再現や
# 「有効化前タスクは covered にならない」観測の初期状態づくりに使う。
variable "enable_guardduty" {
  description = "true で GuardDuty Runtime Monitoring(ECS Fargate agent)+ guardduty-data endpoint を作成。"
  type        = bool
  default     = true
}

# 既存 detector を import して管理する。account/region で detector は singleton なので
# 新規作成できない(import しないと 'detector already exists' で apply 失敗)。
#   terraform import 'module.guardduty[0].aws_guardduty_detector.this' <detector-id>
variable "guardduty_detector_id" {
  description = "import 済みの既存 GuardDuty detector id(参考メモ用。import 先の指定は CLI で行う)。"
  type        = string
  default     = "22c83e4297db19827bde3d6f455580fd"
}

# guardduty-data endpoint をわざと作らず、private 構成でサイドカーがテレメトリを
# 送れない = coverage UNHEALTHY を再現するためのトグル。
variable "create_guardduty_data_endpoint" {
  description = "false で guardduty-data VPC endpoint を作らない(UNHEALTHY 再現用)。"
  type        = bool
  default     = true
}
