variable "region" {
  description = "SES 受信を行うリージョン。inbound endpoint と SNS/Lambda の配置先。"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソース名 prefix に使う識別子"
  type        = string
  default     = "ses-receive"
}

variable "domain" {
  description = "受信対象ドメイン。Route53 Domains 登録済みであること。"
  type        = string
  default     = "example.com"
}
