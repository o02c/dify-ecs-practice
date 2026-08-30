variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name" {
  type    = string
  default = "gd-tgw"
}

variable "central_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "spoke_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

# 直接使う image (spoke は public IP を持つので public.ecr.aws から直接 pull)。
variable "app_image" {
  type    = string
  default = "public.ecr.aws/nginx/nginx:alpine"
}

variable "enable_guardduty" {
  type    = bool
  default = true
}
