variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "sandbox_name" {
  type    = string
  default = "ses-inbound-v3"
}

variable "domain" {
  type    = string
  default = "o2c.click"
}

variable "allowed_recipients" {
  type    = list(string)
  default = ["inbox@o2c.click"]
}

variable "allow_list_domains" {
  type    = list(string)
  default = ["gmail.com"]
}

variable "killswitch_received_threshold" {
  type    = number
  default = 50
}

variable "killswitch_invocation_threshold" {
  type    = number
  default = 50
}

variable "slack_team_id" {
  description = "AWS Chatbot 連携済の Slack Workspace ID。空のままなら Chatbot リソースを作成しない。"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "通知先 Slack Channel ID (例: C0XXXXXXXXX)。空のままなら Chatbot リソースを作成しない。"
  type        = string
  default     = ""
}
