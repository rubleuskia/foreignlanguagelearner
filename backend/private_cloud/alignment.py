"""JWT authentication outside the reused, bounded alignment service."""
import base64
import copy
import hashlib
from backend.alignment import api as alignment_api
from backend.alignment.service import AlignmentService
from backend.cloud.errors import CloudError
from .api import authenticate, runtime, response


class OperatorAlignmentService(AlignmentService):
    def __init__(self, *args, owner, **kwargs):
        super().__init__(*args, **kwargs)
        self.owner = owner

    def _job_metadata(self):
        return {'operator_subject': self.owner}

    def _authorized_job(self, job_id, authorization):
        job = super()._authorized_job(job_id, authorization)
        if job.get('operator_subject') != self.owner:
            from backend.alignment.errors import NotFound
            raise NotFound()
        return job


def handler(event, context):
    try:
        cognito, repo, _ = runtime()
        owner = authenticate(event, cognito, repo)
        service = alignment_api.build_service()
        scoped = OperatorAlignmentService(service.repository, service.storage, service.workflow,
            bucket=service.bucket, state_machine_arn=service.state_machine_arn,
            accept_new_jobs=service.accept_new_jobs, owner=owner)
        # Internal authority is never returned to the client or accepted without JWT validation.
        internal = base64.urlsafe_b64encode(hashlib.sha256(('operator:' + owner).encode()).digest()).decode().rstrip('=')
        translated = copy.deepcopy(event)
        translated['headers'] = {k:v for k,v in event.get('headers', {}).items() if k.lower() != 'authorization'}
        translated['headers']['authorization'] = 'Bearer ' + internal
        if event.get('isBase64Encoded'):
            try:
                translated['body'] = base64.b64decode(event.get('body') or '', validate=True).decode()
            except (ValueError, UnicodeError):
                raise CloudError('INVALID_JSON') from None
        # No shared global service mutation across operators or warm invocations.
        return alignment_api.handle(translated, context, scoped)
    except CloudError as error:
        return response(error.status, {'error': {'code': error.code}})
    except Exception:
        return response(500, {'error': {'code': 'INFRASTRUCTURE_FAILURE'}})
