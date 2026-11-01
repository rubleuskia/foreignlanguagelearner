"""Account-only alignment; capability and session Authorization are never interchangeable."""
import hashlib
from backend.alignment.service import AlignmentService
from backend.alignment.errors import NotFound
from backend.cloud.errors import CloudError


class AccountAlignmentService(AlignmentService):
    def __init__(self, *args, owner, usage, **kwargs):
        super().__init__(*args, **kwargs)
        self.owner, self.usage = owner, usage

    def _current_access(self):
        account = self.usage.account(self.owner)
        self.repository.policy.access(account or {}, self.repository.billing.subscriptions(account or {}), self.clock(), 'alignments')

    def create(self, body, authorization, idem_header):
        self._current_access()
        return super().create(body, authorization, idem_header)

    def upload_urls(self, job_id, body, authorization):
        self._authorized_job(job_id, authorization)
        self._current_access()
        return super().upload_urls(job_id, body, authorization)

    def _create_authority(self, authorization, idem_key):
        # This namespace is deliberately not a capability hash, even if v1 were misrouted.
        return 'account#' + hashlib.sha256(f'{self.owner}:{idem_key}'.encode()).hexdigest()

    def _job_metadata(self): return {'owner_user_id': self.owner, 'delete_after': self.clock()+90*86400}

    def _authorized_job(self, job_id, authorization):
        if (self.usage.account(self.owner) or {}).get('state') != 'active': raise CloudError('ACCOUNT_DISABLED', 403)
        job = self.repository.get_job(job_id)
        if not job or job.get('owner_user_id') != self.owner: raise NotFound()
        return job
