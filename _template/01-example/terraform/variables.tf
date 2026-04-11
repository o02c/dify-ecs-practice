variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子。各 sandbox で必ず書き換える。"
  type        = string
  default     = "example"
}
