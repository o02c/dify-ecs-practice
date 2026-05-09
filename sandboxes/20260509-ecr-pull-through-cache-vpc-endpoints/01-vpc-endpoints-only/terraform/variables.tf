variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子"
  type        = string
  default     = "ecr-ptc-vpce"
}

variable "ptc_prefix" {
  description = "Pull Through Cache の ECR repository prefix (上流: public.ecr.aws)"
  type        = string
  default     = "ecr-public"
}
