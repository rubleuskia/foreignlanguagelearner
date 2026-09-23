"""Step Functions finalizer: validate private worker output before publishing success."""
from __future__ import annotations

import base64
from typing import Any

from .aws_adapters import S3Store
from .config import Config
from .domain import ERROR_CODES, epoch_now, validate_manifest
from .repository import DynamoRepository


def _error_code(event: dict[str, Any], job: dict[str, Any], storage: S3Store) -> tuple[str, dict[str, Any]]:
    outcome = event.get("outcome")
    if isinstance(outcome, dict):
        code = outcome.get("error_code")
        return (code if code in ERROR_CODES else "INFRASTRUCTURE_FAILURE",
                outcome.get("diagnostic_artifacts", {}))
    key = event.get("outcome_key") or job.get("worker_outcome_key")
    version = event.get("outcome_version_id") or job.get("worker_outcome_version_id")
    if key and version:
        try:
            loaded = storage.get_json(key, version)
            code = loaded.get("error_code")
            return (code if code in ERROR_CODES else "INFRASTRUCTURE_FAILURE",
                    loaded.get("diagnostic_artifacts", {}))
        except Exception:
            pass
    reason = event.get("safe_failure", "")
    if reason == "States.Timeout":
        return "WORKER_TIMEOUT", {}
    containers = event.get("task", {}).get("Containers", [])
    exit_code = containers[0].get("ExitCode") if containers else None
    if exit_code == 137:
        return "WORKER_RESOURCE_LIMIT", {}
    if reason in {"OutOfMemoryError", "TaskFailedToStart"}:
        return "WORKER_RESOURCE_LIMIT", {}
    return "INFRASTRUCTURE_FAILURE", {}


def finalize_event(event: dict[str, Any], repository: DynamoRepository, storage: S3Store,
                   now: int) -> dict[str, Any]:
    job = repository.get_job(event["job_id"])
    if not job:
        return {"job_id": event["job_id"], "status": "missing"}
    if job["status"] == "cancelling":
        updated = repository.finalize(job, status="cancelled", now=now)
        return {"job_id": job["job_id"], "status": updated["status"]}
    if job["status"] not in {"starting", "running"}:
        return {"job_id": job["job_id"], "status": job["status"]}

    manifest_key = event.get("manifest_key") or job.get("manifest_key")
    manifest_version = event.get("manifest_version_id") or job.get("manifest_version_id")
    worker_exit_code = event.get("worker_exit_code")
    if worker_exit_code is None:
        containers = event.get("task", {}).get("Containers", [])
        worker_exit_code = containers[0].get("ExitCode") if containers else None
    if worker_exit_code == 0 and manifest_key and manifest_version:
        try:
            raw = storage.get_json(manifest_key, manifest_version)
            manifest = validate_manifest(raw, job=job, manifest_key=manifest_key,
                                         manifest_version_id=manifest_version)
            for artifact in manifest.artifacts.values():
                head = storage.head(artifact["key"], artifact["version_id"])
                expected_checksum = base64.b64encode(bytes.fromhex(artifact["sha256"])).decode()
                if (head.get("VersionId") != artifact["version_id"]
                        or head.get("ContentLength") != artifact["size_bytes"]
                        or head.get("ChecksumSHA256") != expected_checksum):
                    raise ValueError("Artifact identity does not match the manifest")
            fields = {
                "manifest_key": manifest.key, "manifest_version_id": manifest.version_id,
                "requires_review": manifest.requires_review, "counts": manifest.counts,
                "artifacts": manifest.artifacts,
            }
            status = "succeeded_with_review" if manifest.requires_review else "succeeded"
            updated = repository.finalize(job, status=status, now=now, manifest=fields)
            return {"job_id": job["job_id"], "status": updated["status"]}
        except Exception:
            # Manifest parsing details may contain user content and are intentionally not logged.
            pass
    code, diagnostics = _error_code(event, job, storage)
    fields = {"diagnostic_artifacts": diagnostics} if diagnostics else None
    updated = repository.finalize(job, status="failed", now=now, error_code=code, manifest=fields)
    return {"job_id": job["job_id"], "status": updated["status"], "error_code": code}


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    import boto3

    config = Config.from_env()
    repository = DynamoRepository(boto3.client("dynamodb"), config.table_name)
    storage = S3Store(boto3.client("s3"), config.bucket_name)
    return finalize_event(event, repository, storage, epoch_now())
