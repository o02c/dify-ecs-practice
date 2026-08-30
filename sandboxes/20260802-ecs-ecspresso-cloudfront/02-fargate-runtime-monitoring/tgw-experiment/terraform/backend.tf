# 一時検証。tfstate は local。検証後 destroy して捨てる。
terraform {
  backend "local" {}
}
