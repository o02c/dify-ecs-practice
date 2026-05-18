variable "name" {
  description = "リソース名 prefix (例: ses-inbound-v3)"
  type        = string
}

variable "region" {
  description = "SES 受信を行うリージョン"
  type        = string
}

variable "domain" {
  description = "受信対象ドメイン"
  type        = string
}

variable "allowed_recipients" {
  description = "受信を許可するフルアドレスのリスト。空なら [var.domain] (catchall) を使う。"
  type        = list(string)
  default     = []
}

variable "allow_list_domains" {
  description = "Lambda の env var ALLOW_LIST_DOMAINS に渡す送信元ドメイン allow list。空なら全許可。"
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "Lambda の CloudWatch Log Group の retention (日)"
  type        = number
  default     = 14
}

variable "ip_block_list" {
  description = "SES Receipt Filter で接続元 IP を block する CIDR のセット"
  type        = set(string)
  default     = []
}

variable "ip_allow_list" {
  description = "SES Receipt Filter で接続元 IP を allow する CIDR のセット"
  type        = set(string)
  default     = []
}

variable "manage_registered_domain" {
  description = "Route53 Domains の name_server を terraform で同期するか。同一アカウントに登録されている場合のみ true"
  type        = bool
  default     = true
}

variable "enable_killswitch" {
  description = "受信数 / Lambda 起動数が閾値超えしたら自動で active rule set を解除する killswitch を有効化"
  type        = bool
  default     = false
}

variable "killswitch_received_threshold" {
  description = "killswitch 発火する SES Received Sum / period の閾値"
  type        = number
  default     = 100
}

variable "killswitch_invocation_threshold" {
  description = "killswitch 発火する Lambda Invocations Sum / period の閾値"
  type        = number
  default     = 100
}

variable "killswitch_period_seconds" {
  description = "killswitch アラーム評価ウィンドウ (秒)"
  type        = number
  default     = 300
}

variable "archive_lifecycle_ia_days" {
  description = "S3 archive を STANDARD_IA に移すまでの日数"
  type        = number
  default     = 30
}

variable "archive_lifecycle_expiration_days" {
  description = "S3 archive を削除するまでの日数"
  type        = number
  default     = 365
}

variable "slack_team_id" {
  description = "AWS Chatbot 連携済の Slack Workspace ID (Team ID)。空にすると Chatbot リソースを作成しない。"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "AWS Chatbot から alerts を投稿する Slack Channel ID (例: C0XXXXXXXXX)。空にすると Chatbot リソースを作成しない。"
  type        = string
  default     = ""
}
