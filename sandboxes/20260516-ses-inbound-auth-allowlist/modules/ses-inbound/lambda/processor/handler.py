"""SES → SNS → Lambda 受信メールの多段判定 processor。

env var:
  ALLOW_LIST_DOMAINS: カンマ区切り。空なら全 sender ドメイン許可。

判定段:
  1. headersTruncated → INFO
  2. dmarcVerdict == PASS でなければ reject (dmarcPolicy も併記)
  3. spam/virus FAIL なら reject
  4. commonHeaders.from のドメインが allow list にあるか
  通過 → ACCEPTED で件名 / From / To / 本文先頭をログ
"""

import email
import json
import logging
import os
from email.message import Message
from email.utils import parseaddr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BODY_PREVIEW_CHARS = 500

ALLOW_LIST_DOMAINS: set[str] = {
    d.strip().lower()
    for d in os.environ.get("ALLOW_LIST_DOMAINS", "").split(",")
    if d.strip()
}


def handler(event, context):
    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        message_raw = sns.get("Message", "")
        try:
            message = json.loads(message_raw)
        except json.JSONDecodeError:
            logger.exception("SNS message body is not JSON")
            continue

        if message.get("notificationType") != "Received":
            logger.info("skip notificationType=%s", message.get("notificationType"))
            continue

        mail = message.get("mail", {})
        receipt = message.get("receipt", {})
        content = message.get("content", "")
        message_id = mail.get("messageId")

        if mail.get("headersTruncated") is True:
            logger.warning("WARN headers: headersTruncated=true messageId=%s", message_id)

        if not _passes_authentication(receipt, message_id):
            continue
        if not _passes_scan(receipt, message_id):
            continue
        if not _passes_allow_list(mail, message_id):
            continue

        msg = email.message_from_string(content)
        logger.info(
            "ACCEPTED messageId=%s Subject=%s From=%s To=%s",
            message_id, msg.get("Subject"), msg.get("From"), msg.get("To"),
        )
        logger.info("Body preview:\n%s", _body_preview(msg))

    return {"statusCode": 200}


def _passes_authentication(receipt: dict, message_id: str) -> bool:
    dmarc = _verdict(receipt, "dmarcVerdict")
    if dmarc == "PASS":
        return True
    logger.warning(
        "WARN auth: dmarcVerdict=%s dmarcPolicy=%s spf=%s dkim=%s messageId=%s — reject",
        dmarc, receipt.get("dmarcPolicy", "-"),
        _verdict(receipt, "spfVerdict"), _verdict(receipt, "dkimVerdict"), message_id,
    )
    return False


def _passes_scan(receipt: dict, message_id: str) -> bool:
    spam = _verdict(receipt, "spamVerdict")
    virus = _verdict(receipt, "virusVerdict")
    if spam == "FAIL" or virus == "FAIL":
        logger.warning(
            "WARN scan: spamVerdict=%s virusVerdict=%s messageId=%s — reject",
            spam, virus, message_id,
        )
        return False
    return True


def _passes_allow_list(mail: dict, message_id: str) -> bool:
    if not ALLOW_LIST_DOMAINS:
        return True

    common_headers = mail.get("commonHeaders") or {}
    from_list = common_headers.get("from") or []
    from_domain = _extract_domain(from_list[0]) if from_list else ""

    envelope_source = (mail.get("source") or "").lower()
    envelope_domain = envelope_source.split("@")[-1] if "@" in envelope_source else ""

    if from_domain and envelope_domain and from_domain != envelope_domain:
        logger.info(
            "INFO sender: From-domain=%s envelope-domain=%s mismatch messageId=%s",
            from_domain, envelope_domain, message_id,
        )

    if from_domain in ALLOW_LIST_DOMAINS:
        return True

    logger.warning(
        "WARN allowlist: from_domain=%s envelope_domain=%s allow_list=%s messageId=%s — reject",
        from_domain, envelope_domain, sorted(ALLOW_LIST_DOMAINS), message_id,
    )
    return False


def _extract_domain(addr_field: str) -> str:
    _, addr = parseaddr(addr_field)
    return addr.split("@")[-1].lower() if "@" in addr else ""


def _verdict(receipt: dict, key: str) -> str:
    return (receipt.get(key) or {}).get("status", "-")


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
