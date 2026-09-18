variable "region" {
  description = "SES 受信を行うリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソース名 prefix"
  type        = string
  default     = "ses-receive-v2"
}

variable "domain" {
  description = "受信対象ドメイン"
  type        = string
  default     = "example.com"
}

variable "process_recipient" {
  description = "Lambda 処理対象のフルアドレス"
  type        = string
  default     = "inbox@example.com"
}

variable "drop_recipient" {
  description = "バウンスして破棄するフルアドレス"
  type        = string
  default     = "noreply@example.com"
}
