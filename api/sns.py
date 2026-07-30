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
"""

from __future__ import annotations

import base64
import json
import logging
import re
import urllib.request
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


class SnsVerificationError(Exception):
    """Raised when a message cannot be proven to have come from AWS."""


def _fetch_certificate(url: str, timeout: int = 10) -> bytes:
    parsed = urlparse(url)
    if parsed.scheme != 'https' or not _CERT_HOST.match(parsed.hostname or ''):
        raise SnsVerificationError(f'Refusing to fetch signing certificate from {parsed.hostname!r}')

    if url in _CERT_CACHE:
        return _CERT_CACHE[url]

    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - host validated above
        pem = resp.read()
    _CERT_CACHE[url] = pem
    return pem


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

    cert_pem = _fetch_certificate(message.get('SigningCertURL') or '')
    public_key = load_pem_x509_certificate(cert_pem).public_key()

    try:
        public_key.verify(
            base64.b64decode(signature),
            _canonical_string(message),
            padding.PKCS1v15(),
            algorithm,
        )
    except (InvalidSignature, ValueError) as exc:
        raise SnsVerificationError('Signature does not match') from exc


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

    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 - host validated above
        return 200 <= resp.status < 300


def parse_message_body(raw: bytes) -> dict:
    try:
        message = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SnsVerificationError('Body is not valid JSON') from exc
    if not isinstance(message, dict):
        raise SnsVerificationError('Body is not a JSON object')
    return message
