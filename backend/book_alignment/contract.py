"""Shared book upload limits. Duration is deliberately not an admission limit."""
import hashlib
import json
import re
from backend.cloud.errors import CloudError

ARCHIVE_LIMIT = 100_000_000
TEXT_LIMIT = 10_000_000
EXPANDED_LIMIT = 1_000_000_000
ENTRY_LIMIT = 1000
LANGUAGES = frozenset({'en', 'fr', 'es', 'de', 'it', 'pl'})
AUDIO_EXTENSIONS = frozenset({'mp3', 'm4a', 'wav'})
TERMINAL = frozenset({'succeeded', 'succeeded_with_review', 'failed'})
SYSTEM_OWNER = 'system'


def validate_create(body):
    if not isinstance(body, dict) or set(body) != {'title', 'language', 'size_bytes', 'sha256'}:
        raise CloudError('INVALID_PARAMETER')
    if not isinstance(body['title'], str) or not 1 <= len(body['title'].strip()) <= 200:
        raise CloudError('INVALID_TITLE')
    if not isinstance(body['language'], str) or body['language'] not in LANGUAGES:
        raise CloudError('INVALID_LANGUAGE')
    size = body['size_bytes']
    if isinstance(size, bool) or not isinstance(size, int) or not 0 < size <= ARCHIVE_LIMIT:
        raise CloudError('INPUT_TOO_LARGE', 413)
    if not isinstance(body['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', body['sha256']):
        raise CloudError('INVALID_CHECKSUM')
    return {**body, 'title': body['title'].strip()}


def fingerprint(body):
    return hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
