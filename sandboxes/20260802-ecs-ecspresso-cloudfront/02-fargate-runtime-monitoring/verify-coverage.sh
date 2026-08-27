#!/usr/bin/env bash
# =========================================================================
# GuardDuty ECS Fargate Runtime Monitoring 充足診断(read-only)
#
# 「管理アカウントで一括自動有効化したのに covered にならない」を、メンバー
# アカウント側から 1-shot で切り分けるための診断。単一アカウント有効化(この
# sandbox)でも同じスクリプトで確認できる(挙動は A/B 同一)。
#
# 使い方:
#   AWS_PROFILE=<member> ./verify-coverage.sh [--region ap-northeast-1] [--cluster NAME]
#
# 実行する AWS 呼び出しは全て参照系(get/list/describe)のみ。変更は行わない。
# 依存: aws cli v2, jq
# =========================================================================
set -uo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --region)  REGION="$2"; shift 2;;
    --cluster) CLUSTER_FILTER="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
export AWS_REGION="$REGION"

command -v jq >/dev/null || { echo "jq が必要です" >&2; exit 2; }

# ---- 出力ヘルパ -------------------------------------------------------
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
ng()   { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
info() { printf '    %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

CAUSES=()  # 未充足サマリの候補

# =========================================================================
hdr "0. 呼び出し元 / detector"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
[ -n "$ACCOUNT" ] && info "account=$ACCOUNT region=$REGION" || { echo "認証に失敗"; exit 2; }

DET="$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null)"
if [ -z "$DET" ] || [ "$DET" = "None" ]; then
  ng "GuardDuty detector が存在しない(この region で GuardDuty 未有効)"
  CAUSES+=("GuardDuty 自体が未有効")
  echo; echo "detector が無いので以降の判定は省略。"; exit 1
fi
info "detector=$DET"

DET_JSON="$(aws guardduty get-detector --detector-id "$DET" --output json 2>/dev/null)"
DET_STATUS="$(echo "$DET_JSON" | jq -r '.Status')"
RM="$(echo "$DET_JSON" | jq -r '.Features[]? | select(.Name=="RUNTIME_MONITORING")')"
RM_STATUS="$(echo "$RM" | jq -r '.Status // "MISSING"')"
FARGATE_STATUS="$(echo "$RM" | jq -r '.AdditionalConfiguration[]? | select(.Name=="ECS_FARGATE_AGENT_MANAGEMENT") | .Status' )"
FARGATE_STATUS="${FARGATE_STATUS:-MISSING}"
# feature 有効化時刻(relaunch 判定の基準)
ENABLED_AT="$(echo "$RM" | jq -r '.AdditionalConfiguration[]? | select(.Name=="ECS_FARGATE_AGENT_MANAGEMENT") | .UpdatedAt // empty')"
[ -z "$ENABLED_AT" ] && ENABLED_AT="$(echo "$RM" | jq -r '.UpdatedAt // empty')"

[ "$DET_STATUS" = "ENABLED" ] && ok "detector ENABLED" || { ng "detector が $DET_STATUS"; CAUSES+=("detector が無効"); }
[ "$RM_STATUS" = "ENABLED" ] && ok "RUNTIME_MONITORING ENABLED" || { ng "RUNTIME_MONITORING=$RM_STATUS"; CAUSES+=("RUNTIME_MONITORING が無効"); }
if [ "$FARGATE_STATUS" = "ENABLED" ]; then
  ok "ECS_FARGATE_AGENT_MANAGEMENT ENABLED (有効化時刻: ${ENABLED_AT:-不明})"
else
  ng "ECS_FARGATE_AGENT_MANAGEMENT=$FARGATE_STATUS(Fargate サイドカー自動注入が無効)"
  CAUSES+=("ECS_FARGATE_AGENT_MANAGEMENT が無効")
fi

# =========================================================================
hdr "1. 組織(管理アカウント自動有効)設定"
ORG_JSON="$(aws guardduty describe-organization-configuration --detector-id "$DET" --output json 2>/dev/null)"
if [ -n "$ORG_JSON" ]; then
  AE_MEMBERS="$(echo "$ORG_JSON" | jq -r '.AutoEnableOrganizationMembers // .AutoEnable // "?"')"
  RM_AE="$(echo "$ORG_JSON" | jq -r '.Features[]? | select(.Name=="RUNTIME_MONITORING") | .AutoEnable // "?"')"
  FG_AE="$(echo "$ORG_JSON" | jq -r '.Features[]? | select(.Name=="RUNTIME_MONITORING") | .AdditionalConfiguration[]? | select(.Name=="ECS_FARGATE_AGENT_MANAGEMENT") | .AutoEnable // "?"')"
  info "AutoEnableOrganizationMembers=$AE_MEMBERS / RUNTIME_MONITORING.AutoEnable=${RM_AE:-?} / ECS_FARGATE.AutoEnable=${FG_AE:-?}"
  if [ "${FG_AE:-}" = "NEW" ]; then
    warn "ECS_FARGATE の AutoEnable=NEW: 既存メンバーには自動適用されない(ALL / 「既存メンバー一括有効」が必要)"
    CAUSES+=("AutoEnable=NEW で既存メンバー未適用の可能性")
  fi
else
  info "この account は委任管理者ではない(組織設定は取得不可)。単一アカウント視点で継続。"
fi

# =========================================================================
hdr "2. coverage(GuardDuty から見た被覆状況)"
STATS="$(aws guardduty get-coverage-statistics --detector-id "$DET" \
  --statistics-type COUNT_BY_COVERAGE_STATUS --output json 2>/dev/null)"
H="$(echo "$STATS" | jq -r '.CoverageStatistics.CountByCoverageStatus.HEALTHY // 0')"
U="$(echo "$STATS" | jq -r '.CoverageStatistics.CountByCoverageStatus.UNHEALTHY // 0')"
info "HEALTHY=$H  UNHEALTHY=$U"
COV="$(aws guardduty list-coverage --detector-id "$DET" --max-results 50 --output json 2>/dev/null)"
UNHEALTHY_ROWS="$(echo "$COV" | jq -r '.Resources[]? | select(.CoverageStatus=="UNHEALTHY")
  | "    - " + (.ResourceDetails.EcsClusterDetails.ClusterName // .ResourceId) + " : " + (.Issue // "")')"
if [ "$U" -gt 0 ] 2>/dev/null; then
  ng "UNHEALTHY なリソースがある。Issue 文言:"
  echo "$UNHEALTHY_ROWS"
  # Issue の代表例を原因候補に反映
  echo "$COV" | jq -e '.Resources[]? | select(.CoverageStatus=="UNHEALTHY") | .Issue' 2>/dev/null \
    | grep -qi 'relaunch\|before enabling' && CAUSES+=("有効化前タスク→relaunch 必要")
  echo "$COV" | jq -e '.Resources[]? | select(.CoverageStatus=="UNHEALTHY") | .Issue' 2>/dev/null \
    | grep -qi 'vpc\|endpoint\|telemetry\|network' && CAUSES+=("guardduty-data endpoint 到達性")
elif [ "$H" -gt 0 ] 2>/dev/null; then
  ok "全リソース HEALTHY"
else
  warn "coverage レコードが 0 件(監視対象タスクが未起動、または有効化直後で未反映)"
fi

# =========================================================================
hdr "3. クラスタ / VPC / endpoint / task 条件"
# 対象クラスタ列挙
if [ -n "$CLUSTER_FILTER" ]; then
  CLUSTERS="$(aws ecs list-clusters --query "clusterArns[?contains(@, '/$CLUSTER_FILTER')]" --output text 2>/dev/null)"
else
  CLUSTERS="$(aws ecs list-clusters --query 'clusterArns' --output text 2>/dev/null)"
fi
[ -z "$CLUSTERS" ] && warn "ECS クラスタが見つからない(cluster 名を --cluster で指定可)"

# macOS の bash 3.2 は連想配列非対応。VPC はスペース区切りリストで重複除去する。
VPC_LIST=""
add_vpc() { case " $VPC_LIST " in *" $1 "*) ;; *) VPC_LIST="$VPC_LIST $1";; esac; }
for CARN in $CLUSTERS; do
  CNAME="${CARN##*/}"
  printf '\n  [cluster] %s\n' "$CNAME"

  # GuardDutyManaged タグ(除外/選択監視の判定)
  CTAGS="$(aws ecs list-tags-for-resource --resource-arn "$CARN" --output json 2>/dev/null)"
  GDM="$(echo "$CTAGS" | jq -r '.tags[]? | select(.key=="GuardDutyManaged") | .value' 2>/dev/null)"
  if [ "$GDM" = "false" ]; then
    warn "GuardDutyManaged=false(このクラスタは監視から除外されている)"
    CAUSES+=("cluster $CNAME が GuardDutyManaged=false で除外")
  elif [ -n "$GDM" ]; then
    info "GuardDutyManaged=$GDM"
  else
    info "GuardDutyManaged タグ無し(既定=全クラスタ監視なら対象。選択監視モードなら対象外)"
  fi

  # サービス列挙 → platformVersion / 起動時刻 / subnet(VPC)を収集
  SARNS="$(aws ecs list-services --cluster "$CARN" --query 'serviceArns' --output text 2>/dev/null)"
  if [ -z "$SARNS" ]; then
    info "service 無し(standalone task の場合は describe-tasks を手動確認)"
  fi
  for SARN in $SARNS; do
    SVC="$(aws ecs describe-services --cluster "$CARN" --services "$SARN" --output json 2>/dev/null)"
    SNAME="$(echo "$SVC" | jq -r '.services[0].serviceName')"
    PV="$(echo "$SVC" | jq -r '.services[0].platformVersion // "?"')"
    SUBNETS="$(echo "$SVC" | jq -r '.services[0].networkConfiguration.awsvpcConfiguration.subnets[]?' 2>/dev/null)"
    TDEF="$(echo "$SVC" | jq -r '.services[0].taskDefinition')"
    printf '    [service] %s (platformVersion=%s)\n' "$SNAME" "$PV"

    # platformVersion >= 1.4.0 / LATEST
    if [ "$PV" = "LATEST" ]; then ok "platformVersion=LATEST"
    else
      MJ="${PV%%.*}"; REST="${PV#*.}"; MN="${REST%%.*}"
      if { [ "${MJ:-0}" -gt 1 ] 2>/dev/null; } || { [ "${MJ:-0}" -eq 1 ] && [ "${MN:-0}" -ge 4 ]; } 2>/dev/null; then
        ok "platformVersion=$PV (>=1.4.0)"
      else
        ng "platformVersion=$PV (<1.4.0 は非対応)"; CAUSES+=("platformVersion<1.4.0")
      fi
    fi

    # execution role
    TD="$(aws ecs describe-task-definition --task-definition "$TDEF" --output json 2>/dev/null)"
    EXEC="$(echo "$TD" | jq -r '.taskDefinition.executionRoleArn // empty')"
    [ -n "$EXEC" ] && ok "execution role あり($(echo "$EXEC" | sed 's#.*/##'))" \
      || { ng "execution role 未設定(サイドカー image を pull 不可)"; CAUSES+=("execution role 未設定"); }

    # relaunch 判定: running task の起動が有効化より前か
    if [ -n "$ENABLED_AT" ]; then
      TASKS="$(aws ecs list-tasks --cluster "$CARN" --service-name "$SNAME" --desired-status RUNNING --query 'taskArns' --output text 2>/dev/null)"
      if [ -n "$TASKS" ]; then
        TJSON="$(aws ecs describe-tasks --cluster "$CARN" --tasks $TASKS --output json 2>/dev/null)"
        EN_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${ENABLED_AT%%.*}" +%s 2>/dev/null || date -d "$ENABLED_AT" +%s 2>/dev/null || echo 0)"
        OLD=0
        while read -r ST; do
          [ -z "$ST" ] && continue
          T_EPOCH="$(date -j -f "%Y-%m-%dT%H:%M:%S" "${ST%%.*}" +%s 2>/dev/null || date -d "$ST" +%s 2>/dev/null || echo 0)"
          [ "$EN_EPOCH" -gt 0 ] && [ "$T_EPOCH" -gt 0 ] && [ "$T_EPOCH" -lt "$EN_EPOCH" ] && OLD=$((OLD+1))
        done <<< "$(echo "$TJSON" | jq -r '.tasks[]?.startedAt // empty')"
        if [ "$OLD" -gt 0 ]; then
          ng "有効化($ENABLED_AT)より前に起動した running task が $OLD 個 → forceNewDeployment で relaunch"
          CAUSES+=("有効化前タスク→relaunch 必要")
        else
          ok "running task は全て有効化後に起動(サイドカー注入対象)"
        fi
        # サイドカー注入の実確認(注入済みなら GuardDuty のコンテナが並ぶ)
        SIDE="$(echo "$TJSON" | jq -r '[.tasks[]?.containers[]?.name] | map(select(test("guard";"i"))) | length')"
        [ "${SIDE:-0}" -gt 0 ] 2>/dev/null && ok "task に GuardDuty サイドカーコンテナを検出" \
          || info "task container にサイドカー未検出(未反映 / 有効化前 / endpoint 不通の可能性)"
      fi
    fi

    for SN in $SUBNETS; do
      VID="$(aws ec2 describe-subnets --subnet-ids "$SN" --query 'Subnets[0].VpcId' --output text 2>/dev/null)"
      [ -n "$VID" ] && [ "$VID" != "None" ] && add_vpc "$VID"
    done
  done
done

# VPC 単位: guardduty-data endpoint / DNS 属性 / SG 443
for VID in $VPC_LIST; do
  printf '\n  [vpc] %s\n' "$VID"
  # DNS 属性
  DS="$(aws ec2 describe-vpc-attribute --vpc-id "$VID" --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text 2>/dev/null)"
  DH="$(aws ec2 describe-vpc-attribute --vpc-id "$VID" --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text 2>/dev/null)"
  if [ "$DS" = "True" ] && [ "$DH" = "True" ]; then ok "enableDnsSupport / enableDnsHostnames 両方 true"
  else ng "VPC DNS 属性が不十分(support=$DS hostnames=$DH)→ private DNS 有効化不可"; CAUSES+=("VPC DNS 属性不足"); fi

  # guardduty-data endpoint
  EP="$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VID" "Name=service-name,Values=com.amazonaws.${REGION}.guardduty-data" \
    --output json 2>/dev/null)"
  EP_STATE="$(echo "$EP" | jq -r '.VpcEndpoints[0].State // empty')"
  EP_DNS="$(echo "$EP" | jq -r '.VpcEndpoints[0].PrivateDnsEnabled // empty')"
  EP_ID="$(echo "$EP" | jq -r '.VpcEndpoints[0].VpcEndpointId // empty')"
  if [ -z "$EP_ID" ]; then
    ng "guardduty-data endpoint が無い(private/NAT なし構成ではテレメトリ送信不可)"
    CAUSES+=("guardduty-data endpoint 欠如")
  else
    [ "$EP_STATE" = "available" ] && ok "guardduty-data endpoint=$EP_ID State=available" \
      || ng "guardduty-data endpoint=$EP_ID State=$EP_STATE"
    [ "$EP_DNS" = "true" ] && ok "PrivateDnsEnabled=true" \
      || { ng "PrivateDnsEnabled=$EP_DNS(名前解決されずテレメトリ不通)"; CAUSES+=("guardduty-data PrivateDns 無効"); }
    # SG 443 ingress
    SGID="$(echo "$EP" | jq -r '.VpcEndpoints[0].Groups[0].GroupId // empty')"
    if [ -n "$SGID" ]; then
      P443="$(aws ec2 describe-security-groups --group-ids "$SGID" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort==`443` || (FromPort==null && IpProtocol==`-1`)]' --output json 2>/dev/null)"
      [ "$(echo "$P443" | jq 'length')" -gt 0 ] 2>/dev/null && ok "endpoint SG が 443 ingress を許可" \
        || { ng "endpoint SG に 443 ingress が無い"; CAUSES+=("guardduty-data SG 443 未許可"); }
    fi
  fi
done

# =========================================================================
hdr "4. メンバーから確認しづらい項目(管理アカウントで要確認)"
info "・SCP で guardduty:SendSecurityTelemetry が Deny されていないか"
info "・SCP で ecs:TagResource(GuardDutyManaged)が過度に Deny されていないか"
info "・組織の AutoEnable=NEW の場合、既存メンバーは「既存メンバー一括有効」操作が必要"
info "・shared VPC の場合、所有者 + 参加者の双方で automated agent 有効化 & 同一 Organization"

# =========================================================================
hdr "サマリ"
printf '  PASS=%d  FAIL=%d  WARN=%d\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ] && [ "${U:-0}" -eq 0 ]; then
  printf '  \033[32m→ 充足。条件を満たしており、有効化後に起動したタスクはサイドカーが注入される。\033[0m\n'
  exit 0
else
  # 最有力原因(重複除去して先頭)
  UNIQ="$(printf '%s\n' "${CAUSES[@]:-}" | awk 'NF' | awk '!seen[$0]++')"
  printf '  \033[31m→ 未充足。最有力候補:\033[0m\n'
  printf '%s\n' "$UNIQ" | sed 's/^/     • /'
  exit 1
fi
