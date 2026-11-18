"""Explicit durable storage configuration. Never fall back to ephemeral function disk."""
import os
from pathlib import Path
from backend.cloud.errors import CloudError

_instance = None


def service():
    global _instance
    if _instance is None:
        location = os.environ.get('EXAM_STORAGE_ROOT', '')
        if not location or not Path(location).is_absolute():
            raise CloudError('EXAMS_NOT_CONFIGURED', 503)
        from .service import Service
        _instance = Service(Path(location))
    return _instance
