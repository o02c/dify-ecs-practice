"""SES → SNS → Lambda で受け取ったメールを多段判定して通ったものだけログに出す。

判定順:
1. authentication: dmarcVerdict が PASS であること (= SPF または DKIM が PASS かつ
   From ヘッダとアラインしている)。PASS 以外 (FAIL / GRAY / NONE / PROCESSING_FAILED)
   はすべて reject。FAIL の場合は dmarcPolicy (送信側の要求) もログに残す。
2. content scan: spamVerdict / virusVerdict が FAIL なら reject。GRAY / PROCESSING_FAILED
   は通す (= 検出不能を過剰に弾かない)。
3. allow list: env var ALLOW_LIST_DOMAINS にカンマ区切りで指定された送信元ドメインに
   `commonHeaders.from` のドメインが一致する場合のみ通す。空なら全許可。

allow list 判定で `commonHeaders.from` を使う理由:
- DMARC PASS が通った後は From ヘッダのドメインが SPF/DKIM とアラインされている
- ユーザーが「gmail.com を許可」と意図する対象は表示上の差出人 = From ヘッダ
- mail.source (envelope MAIL FROM) はバウンス受け取り先で別ドメインのことが多い
  (例: gmail からの送信で source は bounces+xxx@gmail.com、From は alice@gmail.com)

完全アドレス単位の allow list が必要なら env var ALLOW_LIST_ADDRESSES を別途読み込んで
`_passes_allow_list` を拡張する (例: from_address in ALLOW_LIST_ADDRESSES なら true)。
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

        notification_type = message.get("notificationType")
        if notification_type != "Received":
            logger.info("skip notificationType=%s", notification_type)
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
            message_id,
            msg.get("Subject"),
            msg.get("From"),
            msg.get("To"),
        )
        logger.info("Body preview:\n%s", _body_preview(msg))

    return {"statusCode": 200}


def _passes_authentication(receipt: dict, message_id: str) -> bool:
    dmarc = _verdict(receipt, "dmarcVerdict")
    if dmarc == "PASS":
        return True

    # DMARC FAIL のときは送信側ポリシー (dmarcPolicy) もログに残す。
    # reject 要求のメールを通すべきでないことが明確になるため。
    logger.warning(
        "WARN auth: dmarcVerdict=%s dmarcPolicy=%s spf=%s dkim=%s messageId=%s — reject",
        dmarc,
        receipt.get("dmarcPolicy", "-"),
        _verdict(receipt, "spfVerdict"),
        _verdict(receipt, "dkimVerdict"),
        message_id,
    )
    return False


def _passes_scan(receipt: dict, message_id: str) -> bool:
    spam = _verdict(receipt, "spamVerdict")
    virus = _verdict(receipt, "virusVerdict")
    if spam == "FAIL" or virus == "FAIL":
        logger.warning(
            "WARN scan: spamVerdict=%s virusVerdict=%s messageId=%s — reject",
            spam,
            virus,
            message_id,
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
        # DMARC PASS 済なら同じはずだが、SES 経由のリレーや転送だと割れることがある。
        # 監査用に残す (これだけで reject はしない)。
        logger.info(
            "INFO sender: From-domain=%s envelope-domain=%s mismatch messageId=%s",
            from_domain,
            envelope_domain,
            message_id,
        )

    # アドレス単位の allow list が必要なら、ここで以下のような分岐を足す:
    #   ALLOW_LIST_ADDRESSES = {a.lower() for a in os.environ.get("...","").split(",") if a}
    #   _, from_addr = parseaddr(from_list[0])
    #   if from_addr.lower() in ALLOW_LIST_ADDRESSES: return True

    if from_domain in ALLOW_LIST_DOMAINS:
        return True

    logger.warning(
        "WARN allowlist: from_domain=%s envelope_domain=%s allow_list=%s messageId=%s — reject",
        from_domain,
        envelope_domain,
        sorted(ALLOW_LIST_DOMAINS),
        message_id,
    )
    return False


def _extract_domain(addr_field: str) -> str:
    """'Alice <alice@gmail.com>' / 'alice@gmail.com' から domain を取り出す。"""
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
