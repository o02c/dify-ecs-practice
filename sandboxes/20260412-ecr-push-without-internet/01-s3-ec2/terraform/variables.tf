variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子"
  type        = string
  default     = "ecr-push-s3-ec2"
}
