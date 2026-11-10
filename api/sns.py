"""Verification of inbound AWS SNS messages.

The Street Manager open-data feed pushes to a public endpoint on this server,
so the endpoint is reachable by anyone. Everything here exists to make sure a
message actually came from the SNS topic it claims to, before a single field of
it is trusted.

Two things matter most and are easy to get wrong:

* The signing certificate URL is attacker-supplied. It is validated against the
  AWS SNS hostname pattern *before* being fetched, otherwise the endpoint is an
  SSRF primitive that will happily fetch anything and trust the key it finds.
* The canonical string must be built from a fixed field list in a fixed order.
  Signing whatever keys happen to be present would let an attacker add fields
  that are excluded from the signature but read by the handler.

A valid signature is not the whole story either. The Street Manager topic is
open data: every subscriber in the country holds genuinely signed copies of its
messages, and a signature never expires. So a message must also be *recent*
(``max_message_age_seconds``) — otherwise last month's "road closed" can be
posted here again today — and a MessageId is applied once (``is_duplicate``).
"""

from __future__ import annotations

import base64
import json
import logging
import re
import os
import urllib.request
from datetime import datetime, timedelta, timezone as dt_timezone
from urllib.parse import urlparse

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.x509 import load_pem_x509_certificate

logger = logging.getLogger(__name__)

# Only certificates served from an AWS SNS host are acceptable.
_CERT_HOST = re.compile(r'^sns\.[a-z0-9\-]+\.amazonaws\.com$', re.I)

# Fields that make up the signed canonical string, per message type and in the
# order AWS specifies. Subject is included only when present.
_SIGNED_FIELDS = {
    'Notification': ['Message', 'MessageId', 'Subject', 'Timestamp', 'TopicArn', 'Type'],
    'SubscriptionConfirmation': [
        'Message', 'MessageId', 'SubscribeURL', 'Timestamp', 'Token', 'TopicArn', 'Type',
    ],
    'UnsubscribeConfirmation': [
        'Message', 'MessageId', 'SubscribeURL', 'Timestamp', 'Token', 'TopicArn', 'Type',
    ],
}

_CERT_CACHE: dict[str, bytes] = {}

# How old a message's own (signed) Timestamp may be. SNS normally delivers in
# seconds; its retries for an HTTPS endpoint that is down run for longer than
# this, so an outage of over an hour loses the events published at its start —
# accepted, because the alternative is that any old signed message stays
# replayable for as long as retries could conceivably last. Override with
# SNS_MAX_MESSAGE_AGE_SECONDS (settings or environment).
DEFAULT_MAX_MESSAGE_AGE_SECONDS = 60 * 60
# Clock skew allowed for a Timestamp slightly ahead of this server.
MAX_FUTURE_SKEW_SECONDS = 5 * 60


def max_message_age_seconds() -> int:
    from django.conf import settings
    value = getattr(settings, 'SNS_MAX_MESSAGE_AGE_SECONDS', None)
    if value is None:
        value = os.environ.get('SNS_MAX_MESSAGE_AGE_SECONDS') or DEFAULT_MAX_MESSAGE_AGE_SECONDS
    try:
        return max(60, int(value))
    except (TypeError, ValueError):
        return DEFAULT_MAX_MESSAGE_AGE_SECONDS


class SnsVerificationError(Exception):
    """Raised when a message cannot be proven to have come from AWS."""


def _fetch_certificate(url: str, timeout: int = 10) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != 'https' or not _CERT_HOST.match(parsed.hostname or ''):
        raise SnsVerificationError(f'Refusing to fetch signing certificate from {parsed.hostname!r}')

    if url in _CERT_CACHE:
        return _CERT_CACHE[url]

    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - host validated above
            pem = resp.read(64 * 1024)
    except (OSError, ValueError) as exc:
        # URLError/HTTPError/timeouts are OSErrors. Unverifiable means
        # rejected, not a 500: the URL is the sender's to choose, so a failure
        # to fetch it is their message's problem, not this server's.
        raise SnsVerificationError(f'Could not fetch the signing certificate: {exc}') from exc
    # Cached by verify_message, and only once it has verified a signature:
    # the URL's path and query are the sender's, and caching whatever came
    # back would let them grow this dict without limit.
    return pem


def _check_fresh(message: dict, now: datetime | None = None) -> None:
    """Raise unless the message's signed Timestamp is recent."""
    raw = message.get('Timestamp')
    try:
        text = str(raw).strip()
        if text.endswith('Z'):
            text = text[:-1] + '+00:00'
        stamp = datetime.fromisoformat(text)
    except (TypeError, ValueError) as exc:
        raise SnsVerificationError(f'Unreadable Timestamp {raw!r}') from exc
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=dt_timezone.utc)
    now = now or datetime.now(dt_timezone.utc)
    if now - stamp > timedelta(seconds=max_message_age_seconds()):
        raise SnsVerificationError(f'Message is too old ({raw})')
    if stamp - now > timedelta(seconds=MAX_FUTURE_SKEW_SECONDS):
        raise SnsVerificationError(f'Message is dated in the future ({raw})')


def _canonical_string(message: dict) -> bytes:
    msg_type = message.get('Type')
    fields = _SIGNED_FIELDS.get(msg_type)
    if not fields:
        raise SnsVerificationError(f'Unknown SNS message type {msg_type!r}')

    parts = []
    for field in fields:
        if field == 'Subject' and 'Subject' not in message:
            continue
        value = message.get(field)
        if value is None:
            raise SnsVerificationError(f'Message is missing signed field {field!r}')
        parts.append(f'{field}\n{value}\n')
    return ''.join(parts).encode('utf-8')


def verify_message(message: dict, allowed_topic_arns: list[str] | None = None) -> None:
    """Raise [SnsVerificationError] unless `message` is a genuine SNS message.

    When `allowed_topic_arns` is given, the message's topic must be one of them —
    a valid signature only proves AWS sent it, not that it came from a topic we
    actually subscribed to.
    """
    topic = message.get('TopicArn')
    if allowed_topic_arns and topic not in allowed_topic_arns:
        raise SnsVerificationError(f'Unexpected topic {topic!r}')

    version = str(message.get('SignatureVersion', '1'))
    if version == '1':
        algorithm = hashes.SHA1()
    elif version == '2':
        algorithm = hashes.SHA256()
    else:
        raise SnsVerificationError(f'Unsupported SignatureVersion {version!r}')

    signature = message.get('Signature')
    if not signature:
        raise SnsVerificationError('Message has no Signature')

    # Cheap and local, so before the certificate fetch: a stale message never
    # costs an outbound request. Timestamp is one of the signed fields, so the
    # signature check below is what makes this trustworthy.
    _check_fresh(message)

    cert_url = message.get('SigningCertURL') or ''
    cert_pem = _fetch_certificate(cert_url)
    try:
        public_key = load_pem_x509_certificate(cert_pem).public_key()
    except Exception as exc:  # malformed PEM, unsupported key type
        raise SnsVerificationError('Signing certificate could not be read') from exc

    try:
        public_key.verify(
            base64.b64decode(signature),
            _canonical_string(message),
            padding.PKCS1v15(),
            algorithm,
        )
    except (InvalidSignature, ValueError, TypeError, AttributeError) as exc:
        raise SnsVerificationError('Signature does not match') from exc

    # Only a certificate that has just verified a message is worth keeping.
    if len(_CERT_CACHE) < 32:
        _CERT_CACHE[cert_url] = cert_pem


def is_duplicate(message: dict) -> bool:
    """True when this MessageId has already been accepted recently.

    Call only for a message that has passed [verify_message] — MessageId is a
    signed field, so a verified one can't be forged to dodge this. Remembered
    for as long as a message stays fresh (plus the skew allowance): once it is
    older than that, the freshness check refuses it anyway. Uses the shared
    cache, so both gunicorn workers see the same set.
    """
    from django.core.cache import cache
    message_id = message.get('MessageId')
    if not message_id:
        return False
    ttl = max_message_age_seconds() + MAX_FUTURE_SKEW_SECONDS
    try:
        return not cache.add(f'sns-seen:{str(message_id)[:200]}', 1, ttl)
    except Exception:  # a cache hiccup must not drop a genuine event
        logger.exception('SNS duplicate check failed; accepting the message')
        return False


def confirm_subscription(message: dict, timeout: int = 10) -> bool:
    """Complete an SNS subscription handshake by calling its SubscribeURL.

    Only ever call this for a message that has already passed [verify_message] —
    the URL comes from the message body, so an unverified one points wherever
    the sender likes.
    """
    url = message.get('SubscribeURL')
    if not url:
        return False
    parsed = urlparse(url)
    if parsed.scheme != 'https' or not _CERT_HOST.match(parsed.hostname or ''):
        logger.warning('Refusing to confirm subscription via %s', parsed.hostname)
        return False

    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - host validated above
            return 200 <= resp.status < 300
    except (OSError, ValueError) as exc:
        logger.warning('SNS subscription confirmation failed: %s', exc)
        return False


def parse_message_body(raw: bytes) -> dict:
    try:
        message = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SnsVerificationError('Body is not valid JSON') from exc
    if not isinstance(message, dict):
        raise SnsVerificationError('Body is not a JSON object')
    return message
