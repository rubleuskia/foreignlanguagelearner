import time
import uuid
from backend.cloud.errors import CloudError
from .contract import fingerprint, validate_input, validate_output
from .policy import period
from .provider import ProviderFailure


class TranslationService:
    def __init__(self, repository, billing, policy, provider=None, clock=time.time):
        self.repo, self.billing, self.policy, self.provider, self.clock = repository, billing, policy, provider, clock

    def account(self, owner):
        account = self.repo.account(owner)
        if not account or account['state'] != 'active': raise CloudError('ACCOUNT_DISABLED', 403)
        return account

    def submit(self, owner, kind, payload, key):
        account = self.account(owner)
        payload = validate_input(kind, payload)
        try: key = str(uuid.UUID(key))
        except (ValueError, TypeError, AttributeError): raise CloudError('INVALID_IDEMPOTENCY_KEY') from None
        request_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f'fll:{owner}:{key}'))
        digest = fingerprint({'kind': kind, 'input': payload})
        existing = self.repo.request(request_id)
        if existing:
            if existing['fingerprint'] != digest: raise CloudError('IDEMPOTENCY_CONFLICT', 409)
            return self.status(owner, request_id)
        if not self.policy.enabled: raise CloudError('NEW_TRANSLATIONS_DISABLED', 503)
        now = int(self.clock())
        subscription, allowance = self.policy.access(account, self.billing.subscriptions(account), now)
        period_id, reset_at = period(now)
        record = {'request_id': request_id, 'user_id': owner, 'kind': kind, 'feature': 'translations',
            'state': 'accepted', 'revision': 1, 'fingerprint': digest, 'created_at': now, 'deadline': now + 600,
            'period_id': period_id, 'reset_at': reset_at, 'policy_version': self.policy.version,
            'model': self.policy.model, 'output_tokens': self.policy.output_tokens,
            'delete_after': now + 90 * 86400}
        try:
            self.repo.admit(record, payload, subscription, allowance, self.policy, now)
        except CloudError:
            existing = self.repo.request(request_id)
            if existing and existing['fingerprint'] == digest: return self.status(owner, request_id)
            if existing: raise CloudError('IDEMPOTENCY_CONFLICT', 409)
            raise
        return self.status(owner, request_id)

    def status_by_key(self, owner, key):
        self.account(owner)
        try: key = str(uuid.UUID(key))
        except (ValueError, TypeError, AttributeError): raise CloudError('INVALID_IDEMPOTENCY_KEY') from None
        return self.status(owner, str(uuid.uuid5(uuid.NAMESPACE_URL, f'fll:{owner}:{key}')))

    def status(self, owner, request_id):
        self.account(owner)
        record = self.repo.request(request_id)
        if not record or record['user_id'] != owner: raise CloudError('NOT_FOUND', 404)
        now = int(self.clock())
        if now >= record['delete_after']: raise CloudError('REQUEST_EXPIRED', 410)
        response = {k: record[k] for k in ['request_id', 'state', 'policy_version', 'kind', 'created_at']}
        response['schema_version'] = 1
        if record['state'] == 'succeeded':
            content = self.repo.content(request_id)
            if not content or content['expires_at'] <= now: raise CloudError('RESULT_EXPIRED', 410)
            response.update(result=content['result'], result_expires_at=content['expires_at'])
        return response

    def cancel(self, owner, request_id):
        self.status(owner, request_id)
        record = self.repo.request(request_id)
        if record['state'] == 'accepted': self.repo.finish(record, 'cancelled', int(self.clock()))
        return self.status(owner, request_id)

    def execute(self, request_id):
        record = self.repo.request(request_id)
        if not record or record['state'] != 'accepted': return
        now = int(self.clock())
        content = self.repo.content(request_id)
        if (record['policy_version'] != self.policy.version or not content or content['expires_at'] <= now or record['deadline'] <= now
                or (self.repo.account(record['user_id']) or {}).get('state') != 'active'):
            self.repo.finish(record, 'cancelled', now)
            return
        # Validate before claiming; after claim no retry can ever submit a second inference.
        try: payload = validate_input(record['kind'], content['input'])
        except (CloudError, KeyError, TypeError):
            self.repo.finish(record, 'failed', now)
            return
        claimed = self.repo.claim(record, now)
        if not claimed: return
        try:
            result, tokens = self.provider.run(record['kind'], payload, record['model'], record['output_tokens'])
            validate_output(record['kind'], result, payload)
        except ProviderFailure as error:
            self.repo.finish(claimed, 'outcome_unknown' if error.unknown else 'failed', int(self.clock()), tokens=error.tokens)
            return
        except Exception:
            # An unexpected failure after claim may have happened after external submission.
            self.repo.finish(claimed, 'outcome_unknown', int(self.clock()))
            return
        self.repo.finish(claimed, 'succeeded', int(self.clock()), result, tokens)

    def maintain(self, record, enqueue):
        now = int(self.clock())
        active = (self.repo.account(record['user_id']) or {}).get('state') == 'active'
        if record['state'] == 'accepted':
            if record['deadline'] <= now or not active: self.repo.finish(record, 'cancelled', now)
            else: enqueue(record['request_id'])
        elif record['state'] == 'running' and record['deadline'] <= now:
            self.repo.finish(record, 'outcome_unknown', now)
        elif record['state'] not in {'accepted', 'running'} and (not active or record.get('result_expires_at', 0) <= now):
            self.repo.delete_content(record['request_id'])
