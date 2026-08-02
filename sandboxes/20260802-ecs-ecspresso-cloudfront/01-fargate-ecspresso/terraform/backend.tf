# state を S3 remote backend に置く。
# 目的: CodeBuild 上の ecspresso が tfstate プラグインで s3:// を直接参照できるようにする
#       (ローカルの terraform.tfstate は CodeBuild から見えないため)。
#
# bootstrap: このバケットは terraform 管理外。事前に手動作成する (runbook 参照)。
#   aws s3api create-bucket --bucket ecs-ecspresso-cf-tfstate-example --region ap-northeast-1 \
#     --create-bucket-configuration LocationConstraint=ap-northeast-1
#   (+ versioning / encryption / public access block)
#
# ▼ bucket 名はグローバル一意が必要。利用時に自分の一意な値へ変更し、
#   codebuild.tf の tfstate_bucket_arn / ecspresso.yml の url / cleanup.sh の
#   STATE_BUCKET と揃えること。
terraform {
  backend "s3" {
    bucket  = "ecs-ecspresso-cf-tfstate-example"
    key     = "20260802-ecs-ecspresso-cloudfront/terraform.tfstate"
    region  = "ap-northeast-1"
    encrypt = true
  }
}
