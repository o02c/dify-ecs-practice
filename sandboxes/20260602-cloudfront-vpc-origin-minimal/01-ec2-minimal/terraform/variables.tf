variable "region" {
  description = "AWS region。VPC Origins サポート Region のみ。"
  type        = string
  default     = "ap-northeast-1"
}

variable "sandbox_name" {
  description = "リソースのタグや name prefix に使う識別子。"
  type        = string
  default     = "cf-vpc-origin-min"
}

variable "vpc_bpa_mode" {
  description = <<-EOT
    AWS アカウント + region 単位の VPC Block Public Access モード。
      - "off": リソース未作成 (= 既存状態尊重、destroy 時もここに戻る)
      - "block-bidirectional": IGW 経由の in/out 全 block
      - "block-ingress": IGW 経由の inbound のみ block (NAT GW / egress-only IGW の outbound は許可)

    VPC Origin の疎通が各モードで通るかを比較するためのトグル。

    注意: アカウント + region 単位のグローバル設定。同 region の他 VPC にも影響する。
    検証後は必ず "off" に戻して apply するか、terraform destroy で off に戻すこと。
  EOT
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "block-bidirectional", "block-ingress"], var.vpc_bpa_mode)
    error_message = "vpc_bpa_mode は off / block-bidirectional / block-ingress のいずれか。"
  }
}

variable "enable_vpc_bpa_exclusion" {
  description = <<-EOT
    true で本 sandbox の VPC を BPA から除外 (allow-bidirectional)。
    BPA on でも VPC Origin の疎通が維持されるかを確認するためのトグル。
    enable_vpc_bpa = true と組み合わせて使う。
  EOT
  type        = bool
  default     = false
}

variable "use_custom_nacl" {
  description = <<-EOT
    true で private subnet に custom NACL を関連付ける (rule 不在 = implicit deny all)。
    custom_nacl_allow_* を組み合わせて最小許可セットを探る。
  EOT
  type        = bool
  default     = false
}

variable "custom_nacl_allow_ingress_origin_port" {
  description = "custom NACL に「ingress: 0.0.0.0/0 → port 80 (= var.origin_port)」許可 rule を追加するか"
  type        = bool
  default     = false
}

variable "custom_nacl_allow_egress_ephemeral" {
  description = "custom NACL に「egress: 0.0.0.0/0 → port 1024-65535 (ephemeral 応答)」許可 rule を追加するか"
  type        = bool
  default     = false
}

variable "custom_nacl_allow_ingress_ephemeral" {
  description = "custom NACL に「ingress: 0.0.0.0/0 → port 1024-65535」許可 rule を追加するか (CF→EC2 とは別 path の検証用)"
  type        = bool
  default     = false
}

variable "custom_nacl_allow_egress_origin_port" {
  description = "custom NACL に「egress: 0.0.0.0/0 → port 80」許可 rule を追加するか"
  type        = bool
  default     = false
}
