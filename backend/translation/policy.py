"""Explicit operator policy. An empty product map never enables paid compute."""
import calendar
import datetime
import json
import hashlib
from dataclasses import dataclass
from backend.cloud.errors import CloudError


@dataclass(frozen=True)
class Policy:
    version: str
    products: dict
    daily_limit: int
    concurrent_limit: int
    per_user_concurrent: int
    per_user_minute: int
    model: str
    output_tokens: int
    enabled: bool = False
    alignment_enabled: bool = False

    @classmethod
    def load(cls, raw, enabled=False, alignment_enabled=False):
        data = json.loads(raw)
        required = {'version', 'products', 'daily_limit', 'concurrent_limit', 'per_user_concurrent',
                    'per_user_minute', 'model', 'output_tokens'}
        if set(data) != required or not isinstance(data['version'], str) or not data['version']:
            raise ValueError('Invalid cloud policy')
        if data['model'] not in {'gpt-5-mini', 'gpt-5-nano'}:
            raise ValueError('Unsupported service model')
        for key in required - {'version', 'products', 'model'}:
            if type(data[key]) is not int or not 1 <= data[key] <= 100000:
                raise ValueError('Invalid policy limit')
        if data['output_tokens'] > 4096 or data['per_user_concurrent'] > data['concurrent_limit']:
            raise ValueError('Invalid execution limits')
        if not isinstance(data['products'], dict):
            raise ValueError('Invalid product allowances')
        for product, allowances in data['products'].items():
            if not isinstance(product, str) or not product or not isinstance(allowances, dict) or set(allowances) != {'translations', 'alignments'}:
                raise ValueError('Invalid product allowances')
            if any(type(v) is not int or v < 0 or v > 100000 for v in allowances.values()):
                raise ValueError('Invalid product allowance')
        from .provider import CONTEXT_PROMPT, WORD_PROMPT
        from .contract import output_schema, MODEL_REASONING
        effective = json.dumps({'policy':data,'model_settings':MODEL_REASONING,'context_prompt':CONTEXT_PROMPT,'word_prompt':WORD_PROMPT,
            'context_schema':output_schema('context'),'word_schema':output_schema('word')}, sort_keys=True, separators=(',', ':'))
        data['version'] += '-' + hashlib.sha256(effective.encode()).hexdigest()[:16]
        return cls(**data, enabled=enabled, alignment_enabled=alignment_enabled)

    def access(self, account, subscriptions, now, feature='translations'):
        if account.get('state') != 'active':
            raise CloudError('ACCOUNT_DISABLED', 403)
        candidates = [s for s in subscriptions if s['product_id'] in self.products
            and self.products[s['product_id']][feature] > 0
            and s['status'] in {'subscribed', 'grace_period'} and s['access_expires_at'] > now
            and s['verified_at'] + 3600 > now]
        if not candidates:
            raise CloudError('SUBSCRIPTION_REQUIRED', 403)
        chosen = max(candidates, key=lambda s: self.products[s['product_id']][feature])
        return chosen, self.products[chosen['product_id']][feature]


def period(now):
    date = datetime.datetime.fromtimestamp(now, datetime.timezone.utc)
    start = date.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(month=start.month + 1)
    return start.strftime('%Y-%m'), calendar.timegm(end.utctimetuple())
