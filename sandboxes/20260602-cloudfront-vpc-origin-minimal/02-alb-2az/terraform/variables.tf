variable "region" {
  description = "AWS region。VPC Origins サポート Region のみ。"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子。"
  type        = string
  default     = "cf-vpc-origin-alb"
}

variable "vpc_bpa_mode" {
  description = "off / block-bidirectional / block-ingress"
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "block-bidirectional", "block-ingress"], var.vpc_bpa_mode)
    error_message = "vpc_bpa_mode は off / block-bidirectional / block-ingress のいずれか。"
  }
}

variable "enable_vpc_bpa_exclusion_subnet_a" {
  description = "true で subnet a (AZ1) を BPA exclusion (allow-bidirectional) に追加"
  type        = bool
  default     = false
}

variable "enable_vpc_bpa_exclusion_subnet_b" {
  description = "true で subnet b (AZ2) を BPA exclusion (allow-bidirectional) に追加"
  type        = bool
  default     = false
}

variable "use_custom_nacl" {
  description = "true で両 subnet に custom NACL を associate (rule 不在 = implicit deny all)"
  type        = bool
  default     = false
}

variable "custom_nacl_allow_ingress_origin_port" {
  type    = bool
  default = false
}

variable "custom_nacl_allow_egress_ephemeral" {
  type    = bool
  default = false
}

variable "custom_nacl_allow_ingress_ephemeral" {
  type    = bool
  default = false
}

variable "custom_nacl_allow_egress_origin_port" {
  type    = bool
  default = false
}
