#!/usr/bin/env bash
# =========================================================================
# app/Dockerfile を build して私有 ECR へ push する。
#
# ここ(ローカル)だけインターネットを使う。Fargate 側は private subnet から
# ecr.api/ecr.dkr/s3(gw) endpoint 経由で pull するので NAT 不要。
#
# 前提: terraform apply 済み(ECR repo が出来ている)。docker が動くこと。
# 使い方: AWS_PROFILE=terraform ./push-image.sh
# =========================================================================
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-terraform}"
REGION="${AWS_REGION:-ap-northeast-1}"

HERE="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$HERE/terraform"

REPO_URL="$(terraform -chdir="$TF_DIR" output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"

echo "==> ECR login ($REGISTRY)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

echo "==> build (linux/amd64) + push ${REPO_URL}:latest"
docker build --platform linux/amd64 -t "${REPO_URL}:latest" "$HERE/app"
docker push "${REPO_URL}:latest"

echo "==> 新タスクで pull させるため service を force new deployment"
CLUSTER="$(terraform -chdir="$TF_DIR" output -raw cluster_name)"
SERVICE="$(terraform -chdir="$TF_DIR" output -raw service_name)"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
  --force-new-deployment --region "$REGION" >/dev/null
echo "==> done. coverage は verify-coverage.sh で確認。"
