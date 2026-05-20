"""SES inbound 受信を緊急停止する killswitch Lambda。

CloudWatch アラーム → SNS topic → この Lambda が起動して
ses:SetActiveReceiptRuleSet (引数なし) で active rule set を解除する。
これ以降の inbound メールは「マッチする rule なし」 = SMTP 550 reject = 課金なし。

復旧は手動。SES console / CLI で再度 set-active-receipt-rule-set を呼ぶか
terraform apply で aws_ses_active_receipt_rule_set を再作成する。
"""

import json
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ses = boto3.client("ses")


def handler(event, context):
    logger.info("Killswitch invoked: %s", json.dumps(event, default=str))

    try:
        ses.set_active_receipt_rule_set()
    except Exception:
        logger.exception("FAILED to clear active receipt rule set")
        raise

    logger.warning(
        "KILLSWITCH FIRED: SES active receipt rule set cleared. "
        "All inbound mail will be SMTP-rejected until manually restored."
    )
    return {"action": "ses_receiving_disabled"}
