"""SES → SNS → Lambda で受け取ったメールをログに吐く。

01 と同じく SNS message の content フィールドにある生 MIME (UTF-8) を parse する。
"""

import email
import json
import logging
from email.message import Message

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BODY_PREVIEW_CHARS = 500


def handler(event, context):
    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        message_raw = sns.get("Message", "")
        try:
            message = json.loads(message_raw)
        except json.JSONDecodeError:
            logger.exception("SNS message body is not JSON")
            continue

        notification_type = message.get("notificationType")
        if notification_type != "Received":
            logger.info("skip notificationType=%s", notification_type)
            continue

        mail = message.get("mail", {})
        receipt = message.get("receipt", {})
        content = message.get("content", "")

        logger.info(
            "messageId=%s timestamp=%s source=%s destinations=%s",
            mail.get("messageId"),
            mail.get("timestamp"),
            mail.get("source"),
            mail.get("destination"),
        )
        logger.info(
            "spamVerdict=%s virusVerdict=%s spfVerdict=%s dkimVerdict=%s dmarcVerdict=%s",
            _verdict(receipt, "spamVerdict"),
            _verdict(receipt, "virusVerdict"),
            _verdict(receipt, "spfVerdict"),
            _verdict(receipt, "dkimVerdict"),
            _verdict(receipt, "dmarcVerdict"),
        )

        msg = email.message_from_string(content)
        logger.info("Subject: %s", msg.get("Subject"))
        logger.info("From: %s", msg.get("From"))
        logger.info("To: %s", msg.get("To"))
        logger.info("Body preview:\n%s", _body_preview(msg))

    return {"statusCode": 200}


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
