variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子"
  type        = string
  default     = "ecr-push-s3-lambda"
}

variable "crane_version" {
  description = "crane のバージョン"
  type        = string
  default     = "0.20.3"
}
