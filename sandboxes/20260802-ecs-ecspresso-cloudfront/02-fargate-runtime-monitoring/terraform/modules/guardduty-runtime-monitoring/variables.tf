variable "name" {
  description = "リソース name prefix / タグ。"
  type        = string
}

variable "region" {
  description = "AWS region(guardduty-data endpoint の service name に使う)。"
  type        = string
}

variable "vpc_id" {
  description = "Fargate タスクが動く VPC id。guardduty-data endpoint を張る先。"
  type        = string
}

variable "vpc_cidr" {
  description = "endpoint SG の 443 ingress を許可する VPC CIDR。"
  type        = string
}

variable "subnet_ids" {
  description = "guardduty-data interface endpoint の ENI を置く subnet(タスク subnet と同じでよい)。"
  type        = list(string)
}

variable "create_data_endpoint" {
  description = "false で guardduty-data endpoint を作らない(private 構成で UNHEALTHY を再現する用)。"
  type        = bool
  default     = true
}
