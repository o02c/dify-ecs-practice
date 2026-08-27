#!/usr/bin/env bash
# =========================================================================
# 02-fargate-runtime-monitoring の cleanup
#
# 重要な可逆性の注意:
#   detector は account/region の singleton で、この検証では「既存の disabled detector を
#   import」して使っている。そのまま terraform destroy すると TF は DeleteDetector を呼び、
#   GuardDuty ごと消えてしまう(= 元の「disabled detector が居る」状態に戻らない)。
#   そこで destroy 前に detector 系リソースを state から外し(state rm)、最後に CLI で
#   元の DISABLED 状態へ戻す。
#
# 使い方: AWS_PROFILE=terraform ./cleanup.sh
# =========================================================================
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-terraform}"
REGION="${AWS_REGION:-ap-northeast-1}"
DETECTOR_ID="${DETECTOR_ID:-22c83e4297db19827bde3d6f455580fd}"

HERE="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="$HERE/terraform"

echo "==> [1/3] GuardDuty feature を DISABLED に戻す(検証で有効化した分を無効化)"
aws guardduty update-detector --detector-id "$DETECTOR_ID" --region "$REGION" \
  --features 'Name=RUNTIME_MONITORING,Status=DISABLED,AdditionalConfiguration=[{Name=ECS_FARGATE_AGENT_MANAGEMENT,Status=DISABLED}]' \
  >/dev/null 2>&1 || echo "    (feature 無効化スキップ / 既に無効)"

echo "==> [2/3] detector を state から外して terraform destroy"
# detector / feature を TF 管理から外す(存在しなければ無視)。これで destroy が
# DeleteDetector を呼ばない。endpoint/ECS/VPC/ECR/role のみ destroy される。
terraform -chdir="$TF_DIR" state rm \
  'module.guardduty[0].aws_guardduty_detector.this' \
  'module.guardduty[0].aws_guardduty_detector_feature.runtime_monitoring' \
  2>/dev/null || echo "    (detector は既に state 外)"
terraform -chdir="$TF_DIR" destroy -auto-approve

echo "==> [3/3] detector を元の DISABLED へ(検証前は disabled で存在していた)"
aws guardduty update-detector --detector-id "$DETECTOR_ID" --region "$REGION" \
  --no-enable >/dev/null 2>&1 || echo "    (detector 無効化スキップ)"

echo "==> cleanup 完了。detector は削除せず DISABLED に戻した(検証前状態)。"
