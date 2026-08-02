variable "region" {
  description = "AWS region。CloudFront VPC Origins サポート Region のみ。"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子。ecspresso 側の tfstate 参照とも揃える。"
  type        = string
  default     = "ecs-ecspresso-cf"
}

# ---- (任意) VPC BPA -----------------------------------------------------
# [[cloudfront_vpc_origin_bpa]]: VPC Origin は BPA on だと mode を問わず 504 になる。
# subnet 単位 exclusion (allow-bidirectional) で疎通が復活する。
variable "vpc_bpa_mode" {
  description = "off / block-bidirectional / block-ingress"
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "block-bidirectional", "block-ingress"], var.vpc_bpa_mode)
    error_message = "vpc_bpa_mode は off / block-bidirectional / block-ingress のいずれか。"
  }
}

variable "enable_vpc_bpa_exclusion" {
  description = "true で ALB / task を置く両 subnet を BPA exclusion (allow-bidirectional) に追加。BPA on 時の疎通復活用。"
  type        = bool
  default     = false
}
