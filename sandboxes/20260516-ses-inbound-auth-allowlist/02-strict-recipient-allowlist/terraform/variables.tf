variable "region" {
  description = "SES 受信を行うリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソース名 prefix"
  type        = string
  default     = "ses-inbound-strict"
}

variable "domain" {
  description = "受信対象ドメイン"
  type        = string
  default     = "o2c.click"
}

variable "allowed_recipients" {
  description = "受信を許可するフルアドレスのリスト。ここに列挙したアドレス宛 のみ Receipt Rule が match する。列挙外は SES SMTP 中 reject で課金されない。"
  type        = list(string)
  default     = ["inbox@o2c.click"]
}

variable "allow_list_domains" {
  description = "Lambda の env var に渡す送信元ドメイン allow list。空にすると全許可。"
  type        = list(string)
  default     = ["gmail.com"]
}

variable "log_retention_days" {
  description = "Lambda の CloudWatch Log Group の retention (日)。"
  type        = number
  default     = 14
}
