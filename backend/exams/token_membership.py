"""Bounded, source-declared token alphabets shared by package and server grading."""
from __future__ import annotations

import re


def token_pattern(grading):
    pattern = grading.get('token_pattern', '[0-9]+')
    # Only fixed ASCII alphabets are allowed, never user-supplied regex syntax.
    if pattern == '[0-9]+':
        return pattern
    match = re.fullmatch(r'\[([A-Z])-([A-Z])\]', pattern) if isinstance(pattern, str) else None
    if not match or match[1] > match[2]:
        raise ValueError('Token pattern must be ASCII digits or an uppercase letter range')
    return pattern


def normalize_token(value, grading):
    return value.upper() if grading.get('ignore_case') else value


def tokens(value, grading):
    flags = re.ASCII | (re.IGNORECASE if grading.get('ignore_case') else 0)
    return {normalize_token(v, grading) for v in re.findall(token_pattern(grading), value, flags)}


def validate_membership(item):
    grading = item['grading']
    pattern = token_pattern(grading)
    accepted = grading.get('accepted_answers', [])
    flags = re.ASCII | (re.IGNORECASE if grading.get('ignore_case') else 0)
    if (item.get('response_type') != 'text' or not accepted
            or any(not isinstance(a, str) or re.fullmatch(pattern, a, flags) is None for a in accepted)):
        raise ValueError('Membership rules need explicit tokens matching the source alphabet and text input')
    normalized = {normalize_token(a, grading) for a in accepted}
    if len(normalized) != len(accepted) or item['max_score_units'] % len(accepted):
        raise ValueError('Membership points must divide exactly across distinct accepted tokens')
    if (type(grading.get('max_tokens', len(accepted))) is not int
            or grading.get('max_tokens', len(accepted)) != len(accepted)):
        raise ValueError('Token capacity must match the original answer slots')
