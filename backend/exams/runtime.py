"""Explicit durable storage configuration. Never fall back to ephemeral function disk."""
import os
from pathlib import Path
from backend.cloud.errors import CloudError

_instance = None


def service():
    global _instance
    if _instance is None:
        table = os.environ.get('EXAMS_TABLE', '')
        bucket = os.environ.get('EXAMS_BUCKET', '')
        location = os.environ.get('EXAM_STORAGE_ROOT', '')
        if table or bucket:
            if not table or not bucket or location:
                raise CloudError('EXAMS_CONFIGURATION_CONFLICT', 503)
            from .cloud_service import CloudService
            _instance = CloudService.configured(table, bucket, region=os.environ.get('AWS_REGION'))
            return _instance
        if not location or not Path(location).is_absolute():
            raise CloudError('EXAMS_NOT_CONFIGURED', 503)
        from .service import Service
        _instance = Service(Path(location))
    return _instance
