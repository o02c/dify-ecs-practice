variable "region" {
  description = "SES 受信を行うリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソース名 prefix"
  type        = string
  default     = "ses-inbound-v3"
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

variable "allow_list_domains" {
  description = "Lambda の env var に渡す送信元ドメインの allow list。空にすると全許可。"
  type        = list(string)
  default     = ["gmail.com"]
}

variable "ip_block_list" {
  description = "SES Receipt Filter で接続元 IP を block する CIDR のセット。デフォルト空 = 何も block しない。完全ホワイトリスト化するなら ['0.0.0.0/0'] + ip_allow_list で例外指定。"
  type        = set(string)
  default     = []
}

variable "ip_allow_list" {
  description = "SES Receipt Filter で接続元 IP を allow する CIDR のセット。block list の例外として明示許可するレンジ。"
  type        = set(string)
  default     = []
}

variable "log_retention_days" {
  description = "Lambda の CloudWatch Log Group の retention (日)。sandbox なので短め。"
  type        = number
  default     = 14
}
