"""S3 → SNS → Lambda の受信パイプライン processor。

トリガ: S3 ObjectCreated event を SNS topic 経由で受信
入力: SNS message body = S3 event JSON
処理: S3 から raw MIME バイト列を取得 → MIME パース → 多段判定 → ACCEPTED ログ

判定段:
1. Authentication-Results ヘッダから SPF/DKIM/DMARC verdict を抽出、DMARC PASS 必須
2. X-SES-Spam-Verdict / X-SES-Virus-Verdict ヘッダ確認、どちらか FAIL なら reject
3. From ヘッダのドメインが env var ALLOW_LIST_DOMAINS に含まれるか

最大受信サイズ: 40 MB (S3 deliver action の上限)。
"""

import email
import json
import logging
import os
import re
from email.message import Message
from email.utils import parseaddr

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BODY_PREVIEW_CHARS = 500

ALLOW_LIST_DOMAINS: set[str] = {
    d.strip().lower()
    for d in os.environ.get("ALLOW_LIST_DOMAINS", "").split(",")
    if d.strip()
}

s3 = boto3.client("s3")

# Authentication-Results: example.com; spf=pass ...; dkim=pass ...; dmarc=pass ...
_AUTH_RESULT_RE = re.compile(r"\b(spf|dkim|dmarc)\s*=\s*([a-z_]+)", re.IGNORECASE)


def handler(event, context):
    for record in event.get("Records", []):
        sns = record.get("Sns")
        if not sns:
            continue

        try:
            s3_event = json.loads(sns.get("Message") or "")
        except json.JSONDecodeError:
            logger.exception("SNS message body is not JSON")
            continue

        for s3_record in s3_event.get("Records", []):
            _process_s3_record(s3_record)

    return {"statusCode": 200}


def _process_s3_record(s3_record: dict) -> None:
    if s3_record.get("eventSource") != "aws:s3":
        return
    bucket = s3_record.get("s3", {}).get("bucket", {}).get("name")
    key = s3_record.get("s3", {}).get("object", {}).get("key")
    if not bucket or not key:
        return

    # SES が S3 連携セットアップ時に書き込むテスト用オブジェクトはスキップ
    if key.endswith("AMAZON_SES_SETUP_NOTIFICATION"):
        logger.info("skip SES setup probe: s3://%s/%s", bucket, key)
        return

    message_id = key.rsplit("/", 1)[-1]
    logger.info("Processing s3://%s/%s (messageId=%s)", bucket, key, message_id)

    obj = s3.get_object(Bucket=bucket, Key=key)
    raw_bytes = obj["Body"].read()
    size = obj.get("ContentLength", len(raw_bytes))

    # email.message_from_bytes が MIME charset を見て適切にデコードしてくれる
    msg = email.message_from_bytes(raw_bytes)

    if not _passes_authentication(msg, message_id):
        return
    if not _passes_scan(msg, message_id):
        return
    if not _passes_allow_list(msg, message_id):
        return

    logger.info(
        "ACCEPTED messageId=%s size=%d Subject=%s From=%s To=%s",
        message_id, size,
        msg.get("Subject"), msg.get("From"), msg.get("To"),
    )
    logger.info("Body preview:\n%s", _body_preview(msg))


def _passes_authentication(msg: Message, message_id: str) -> bool:
    auth = msg.get("Authentication-Results") or ""
    verdicts = _parse_auth_results(auth)
    dmarc = verdicts.get("dmarc", "").upper()
    if dmarc == "PASS":
        return True

    logger.warning(
        "WARN auth: dmarc=%s spf=%s dkim=%s messageId=%s — reject",
        verdicts.get("dmarc", "-"),
        verdicts.get("spf", "-"),
        verdicts.get("dkim", "-"),
        message_id,
    )
    return False


def _passes_scan(msg: Message, message_id: str) -> bool:
    spam = (msg.get("X-SES-Spam-Verdict") or "").upper()
    virus = (msg.get("X-SES-Virus-Verdict") or "").upper()
    if spam == "FAIL" or virus == "FAIL":
        logger.warning(
            "WARN scan: spamVerdict=%s virusVerdict=%s messageId=%s — reject",
            spam, virus, message_id,
        )
        return False
    return True


def _passes_allow_list(msg: Message, message_id: str) -> bool:
    if not ALLOW_LIST_DOMAINS:
        return True

    _, from_addr = parseaddr(msg.get("From") or "")
    from_domain = from_addr.split("@")[-1].lower() if "@" in from_addr else ""

    if from_domain in ALLOW_LIST_DOMAINS:
        return True

    logger.warning(
        "WARN allowlist: from_domain=%s allow_list=%s messageId=%s — reject",
        from_domain, sorted(ALLOW_LIST_DOMAINS), message_id,
    )
    return False


def _parse_auth_results(raw: str) -> dict:
    """Authentication-Results ヘッダから spf/dkim/dmarc の verdict を取り出す。

    最初に現れた値を優先する。multi-DKIM 等で複数 dkim= がある場合の扱いは要件次第。
    """
    result: dict[str, str] = {}
    for match in _AUTH_RESULT_RE.finditer(raw):
        key = match.group(1).lower()
        value = match.group(2).lower()
        if key not in result:
            result[key] = value
    return result


def _body_preview(msg: Message) -> str:
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                return _decode_part(part)[:BODY_PREVIEW_CHARS]
        return "(no text/plain part)"
    return _decode_part(msg)[:BODY_PREVIEW_CHARS]


def _decode_part(part: Message) -> str:
    payload = part.get_payload(decode=True)
    if not isinstance(payload, bytes):
        return ""
    charset = part.get_content_charset() or "utf-8"
    return payload.decode(charset, errors="replace")
