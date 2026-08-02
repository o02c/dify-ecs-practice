#!/usr/bin/env bash
# =========================================================================
# 20260802-ecs-ecspresso-cloudfront sandbox の完全 cleanup
#
#   1) ECS service 削除            … ecspresso 管理 (terraform state 外) なので先に消す。
#                                     service が残ると ECS cluster を destroy できない。
#   2) terraform destroy           … CloudFront disable 反映で ~20 分。
#   3) state バケット削除          … terraform 管理外 (backend の bootstrap)。
#                                     versioning 有効なので全 version/delete-marker を消して rb。
#
# 使い方: AWS_PROFILE=terraform ./cleanup.sh
# =========================================================================
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-terraform}"
REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER="ecs-ecspresso-cf"
SERVICE="ecs-ecspresso-cf"
STATE_BUCKET="ecs-ecspresso-cf-tfstate-example"

HERE="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$HERE/terraform"

echo "==> [1/3] ECS service 削除 (${CLUSTER}/${SERVICE})"
status="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
  --query 'services[0].status' --output text 2>/dev/null || echo "NONE")"
if [ "$status" = "ACTIVE" ] || [ "$status" = "DRAINING" ]; then
  aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force --region "$REGION" >/dev/null
  echo "    service を削除、INACTIVE になるまで待機..."
  aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" || true
  echo "    done"
else
  echo "    service 無し (status=$status)、スキップ"
fi

echo "==> [2/3] terraform destroy (CloudFront disable で ~20 分)"
terraform -chdir="$TF_DIR" destroy -auto-approve

echo "==> [3/3] state バケット削除 (${STATE_BUCKET}, versioned)"
if aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" 2>/dev/null; then
  while true; do
    payload="$(aws s3api list-object-versions --bucket "$STATE_BUCKET" --region "$REGION" \
      --max-items 500 --output json \
      --query '{Objects: [Versions, DeleteMarkers][] | [].{Key: Key, VersionId: VersionId}}')"
    count="$(printf '%s' "$payload" | python3 -c 'import sys,json; print(len((json.load(sys.stdin).get("Objects") or [])))')"
    [ "$count" = "0" ] && break
    aws s3api delete-objects --bucket "$STATE_BUCKET" --region "$REGION" --delete "$payload" >/dev/null
    echo "    deleted $count versions/markers..."
  done
  aws s3 rb "s3://$STATE_BUCKET" --region "$REGION"
  echo "    state bucket removed"
else
  echo "    state bucket 無し、スキップ"
fi

echo "==> cleanup 完了"
