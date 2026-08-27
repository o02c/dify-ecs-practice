# この approach は監視の挙動観測が目的で、CodeBuild(air-gapped ecspresso)を使わない。
# そのため 01 のような S3 remote backend は不要で、tfstate は local に置く。
# 検証後は terraform destroy してから捨てる(README の設計方針どおり)。
terraform {
  backend "local" {}
}
