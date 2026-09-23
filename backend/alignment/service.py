"""Application service implementing the public HTTP contract."""
from __future__ import annotations

import base64
import hashlib
import json
import uuid
from typing import Any

from .domain import (
    PART_SIZE, RECORD_TTL_SECONDS, RESULT_TTL_SECONDS, UPLOAD_TTL_SECONDS,
    canonical_json, capability_matches, epoch_now, expected_part_size, iso8601,
    part_count, request_hash, seconds_until_utc_reset, token_hash, utc_day,
    validate_completed_parts, validate_create, validate_idempotency_key,
    validate_part_numbers,
)
from .errors import AlignmentError, Conflict, Gone, NotFound, RateLimited


def _sha256_base64(hex_digest: str) -> str:
    return base64.b64encode(bytes.fromhex(hex_digest)).decode()


class AlignmentService:
    def __init__(self, repository: Any, storage: Any, workflow: Any, *, bucket: str,
                 state_machine_arn: str, accept_new_jobs: bool, clock=epoch_now):
        self.repository = repository
        self.storage = storage
        self.workflow = workflow
        self.bucket = bucket
        self.state_machine_arn = state_machine_arn
        self.accept_new_jobs = accept_new_jobs
        self.clock = clock

    def _authorized_job(self, job_id: str, authorization: str | None) -> dict[str, Any]:
        presented = token_hash(authorization)
        job = self.repository.get_job(job_id)
        if not job or not capability_matches(presented, job["access_token_hash"]):
            raise NotFound()
        return job

    def _accepting(self) -> None:
        if not self.accept_new_jobs:
            raise AlignmentError("NEW_JOBS_DISABLED", "New alignment work is temporarily disabled.", 503)

    def create(self, body: Any, authorization: str | None, idem_header: str | None) -> tuple[int, dict[str, Any]]:
        self._accepting()
        access_hash = token_hash(authorization)
        idem_key = validate_idempotency_key(idem_header)
        request = validate_create(body)
        digest = request_hash(request)
        replay = self.repository.get_idempotency(access_hash, idem_key)
        if replay:
            if replay["request_hash"] != digest:
                raise Conflict("IDEMPOTENCY_CONFLICT", "Idempotency key was already used for different content.")
            job = self.repository.get_job(replay["job_id"])
            if not job:
                raise AlignmentError("INFRASTRUCTURE_FAILURE", "Idempotency record has no job.", 500)
            return 200, self._create_response(job, renew_urls=job["status"] == "awaiting_upload")

        now = self.clock()
        job_id = str(uuid.uuid4())
        audio_key = f"jobs/{job_id}/input/audio.{request['audio']['extension']}"
        text_key = f"jobs/{job_id}/input/transcript.txt"
        upload_id = self.storage.create_audio_upload(audio_key, request["audio"]["sha256"])
        job = {
            "pk": f"JOB#{job_id}", "sk": "METADATA", "job_id": job_id,
            "access_token_hash": access_hash, "schema_version": 1,
            "created_at": now, "updated_at": now, "upload_expires_at": now + UPLOAD_TTL_SECONDS,
            "delete_after": now + RECORD_TTL_SECONDS, "status": "awaiting_upload", "revision": 1,
            "profile_id": request["profile_id"], "language": request["language"],
            "allow_untimed_words": request["allow_untimed_words"],
            "expected_audio_bytes": request["audio"]["size_bytes"],
            "expected_text_bytes": request["text"]["size_bytes"],
            "expected_audio_sha256": request["audio"]["sha256"],
            "expected_text_sha256": request["text"]["sha256"],
            "multipart_upload_id": upload_id, "completed_parts": [],
            "audio_key": audio_key, "text_key": text_key,
            "execution_name": f"alignment-{job_id}", "cleanup_pending": False,
            "admission_released": True, "upload_slot_released": False,
            "upload_complete": False,
        }
        try:
            self.repository.create_job(job, idem_key, digest, now)
        except Exception:
            # The lifecycle rule is the final fallback; make a best-effort immediate abort.
            try:
                self.storage.abort_upload(audio_key, upload_id)
            except Exception:
                pass
            replay = self.repository.get_idempotency(access_hash, idem_key)
            if replay and replay["request_hash"] == digest:
                return 200, self._create_response(self.repository.get_job(replay["job_id"]), renew_urls=True)
            raise
        return 201, self._create_response(job, renew_urls=True)

    def _create_response(self, job: dict[str, Any], *, renew_urls: bool) -> dict[str, Any]:
        response = {
            "job_id": job["job_id"], "status": job["status"],
            "upload_expires_at": iso8601(job["upload_expires_at"]),
            "part_size_bytes": PART_SIZE,
            "part_count": part_count(job["expected_audio_bytes"]),
        }
        if renew_urls:
            response["text_upload"] = self.storage.text_put_url(
                job["text_key"], _sha256_base64(job["expected_text_sha256"])
            )
        return response

    def upload_urls(self, job_id: str, body: Any, authorization: str | None) -> dict[str, Any]:
        self._accepting()
        job = self._authorized_job(job_id, authorization)
        now = self.clock()
        if job["status"] != "awaiting_upload":
            raise Conflict("INVALID_STATE", "Upload URLs are available only while awaiting upload.")
        if now >= job["upload_expires_at"]:
            raise Gone("Upload session has expired.")
        values, include_text = validate_part_numbers(body, part_count(job["expected_audio_bytes"]))
        response: dict[str, Any] = {"parts": [
            self.storage.upload_part_url(job["audio_key"], job["multipart_upload_id"], value,
                                         expected_part_size(job["expected_audio_bytes"], value))
            for value in values
        ]}
        if include_text:
            response["text_upload"] = self.storage.text_put_url(
                job["text_key"], _sha256_base64(job["expected_text_sha256"])
            )
        return response

    def upload_status(self, job_id: str, authorization: str | None) -> dict[str, Any]:
        job = self._authorized_job(job_id, authorization)
        parts = job.get("completed_parts", [])
        if job["status"] == "awaiting_upload" and not job.get("upload_complete"):
            try:
                parts = [{"part_number": p["PartNumber"], "etag": p["ETag"], "size_bytes": p["Size"]}
                         for p in self.storage.list_parts(job["audio_key"], job["multipart_upload_id"])]
            except Exception:
                parts = []
        return {"job_id": job_id, "upload_complete": bool(job.get("upload_complete")),
                "parts": parts, "upload_expires_at": iso8601(job["upload_expires_at"])}

    def complete_upload(self, job_id: str, body: Any, authorization: str | None) -> dict[str, Any]:
        job = self._authorized_job(job_id, authorization)
        now = self.clock()
        if job.get("upload_complete"):
            return self.upload_status(job_id, authorization)
        if job["status"] != "awaiting_upload":
            raise Conflict("INVALID_STATE", "Upload cannot be completed in the current state.")
        if now >= job["upload_expires_at"]:
            raise Gone("Upload session has expired.")
        expected_count = part_count(job["expected_audio_bytes"])
        submitted = validate_completed_parts(body, expected_count)
        try:
            remote = self.storage.list_parts(job["audio_key"], job["multipart_upload_id"])
        except Exception:
            remote = None
        if remote is not None:
            if len(remote) != expected_count:
                raise Conflict("UPLOAD_INCOMPLETE", "Uploaded audio parts are incomplete.")
            for submitted_part, actual in zip(submitted, remote):
                number = submitted_part["part_number"]
                if actual["PartNumber"] != number or actual["Size"] != expected_part_size(job["expected_audio_bytes"], number):
                    raise Conflict("UPLOAD_INCOMPLETE", "Uploaded audio part sizes do not match the declaration.")
                if actual["ETag"].strip('"') != submitted_part["etag"].strip('"'):
                    raise Conflict("UPLOAD_INCOMPLETE", "Uploaded audio part ETag does not match.")
            audio_version = self.storage.complete_audio(job["audio_key"], job["multipart_upload_id"], submitted)
            audio_head = self.storage.head(job["audio_key"], audio_version)
            completed = [{"part_number": p["PartNumber"], "etag": p["ETag"], "size_bytes": p["Size"]}
                         for p in remote]
        else:
            # CompleteMultipartUpload may have succeeded even when its HTTP response was lost.
            audio_head = self.storage.head(job["audio_key"])
            audio_version = audio_head.get("VersionId")
            if not audio_version:
                raise Conflict("UPLOAD_INCOMPLETE", "Completed audio object was not found.")
            completed = [{"part_number": p["part_number"], "etag": p["etag"],
                          "size_bytes": expected_part_size(job["expected_audio_bytes"], p["part_number"])}
                         for p in submitted]
        text_head = self.storage.head(job["text_key"])
        text_version = text_head.get("VersionId")
        if audio_head["ContentLength"] != job["expected_audio_bytes"] or text_head["ContentLength"] != job["expected_text_bytes"]:
            raise AlignmentError("CHECKSUM_MISMATCH", "Uploaded object sizes do not match the declaration.", 409)
        if not text_version:
            raise AlignmentError("INFRASTRUCTURE_FAILURE", "Versioned text upload was not found.", 500)
        updated = self.repository.set_upload_complete(
            job, audio_version=audio_version, text_version=text_version,
            completed_parts=completed, now=now,
        )
        return {"job_id": job_id, "upload_complete": True, "parts": updated["completed_parts"],
                "upload_expires_at": iso8601(updated["upload_expires_at"])}

    def start(self, job_id: str, body: Any, authorization: str | None) -> dict[str, Any]:
        self._accepting()
        if body not in ({}, None):
            raise AlignmentError("INVALID_PARAMETER", "Start request must have an empty JSON object.")
        job = self._authorized_job(job_id, authorization)
        if job["status"] != "awaiting_upload":
            return self.status(job_id, authorization)
        if not job.get("upload_complete"):
            raise Conflict("UPLOAD_INCOMPLETE", "Both inputs must be completed before start.")
        now = self.clock()
        canonical = canonical_json({
            "schema_version": 1, "job_id": job_id, "bucket": self.bucket,
            "profile_id": job["profile_id"], "language": job["language"],
            "allow_untimed_words": job["allow_untimed_words"],
            "audio": {"key": job["audio_key"], "version_id": job["audio_version_id"],
                      "size_bytes": job["expected_audio_bytes"], "sha256": job["expected_audio_sha256"]},
            "text": {"key": job["text_key"], "version_id": job["text_version_id"],
                     "size_bytes": job["expected_text_bytes"], "sha256": job["expected_text_sha256"]},
        })
        try:
            job = self.repository.acquire_start(job, canonical, job["execution_name"], self.state_machine_arn, now)
        except RateLimited:
            raise
        arn = self.workflow.start(job["execution_name"], job["canonical_execution_input"])
        job = self.repository.set_execution_arn(job, arn, now)
        return self._status_response(job)

    def status(self, job_id: str, authorization: str | None) -> dict[str, Any]:
        return self._status_response(self._authorized_job(job_id, authorization))

    def _status_response(self, job: dict[str, Any]) -> dict[str, Any]:
        now = self.clock()
        expiry = job.get("result_expires_at")
        return {
            "job_id": job["job_id"], "status": job["status"],
            "stage": job.get("result_stage"), "progress_percent": None,
            "error_code": job.get("error_code"),
            "created_at": iso8601(job["created_at"]), "updated_at": iso8601(job["updated_at"]),
            "completed_at": iso8601(job.get("completed_at")),
            "requires_review": job.get("requires_review"),
            "result_available": bool(job["status"] in {"succeeded", "succeeded_with_review"}
                                     and expiry and now < expiry),
            "result_expires_at": iso8601(expiry),
        }

    def result(self, job_id: str, authorization: str | None) -> dict[str, Any]:
        job = self._authorized_job(job_id, authorization)
        if job["status"] not in {"succeeded", "succeeded_with_review"}:
            raise Conflict("RESULT_NOT_READY", "Alignment result is not available.")
        now = self.clock()
        if now >= job["result_expires_at"]:
            raise Gone("Alignment result has expired.")
        remaining = job["result_expires_at"] - now
        artifacts = {}
        for name, artifact in job["artifacts"].items():
            artifacts[name] = {
                "url": self.storage.download_url(artifact["key"], artifact["version_id"], remaining),
                "size_bytes": artifact["size_bytes"], "sha256": artifact["sha256"],
            }
        return {"job_id": job_id, "artifacts": artifacts,
                "url_expires_at": iso8601(now + min(900, remaining)),
                "result_expires_at": iso8601(job["result_expires_at"]),
                "requires_review": job["requires_review"], "counts": job["counts"]}

    def diagnostics(self, job_id: str, authorization: str | None) -> dict[str, Any]:
        job = self._authorized_job(job_id, authorization)
        if job["status"] not in {"failed", "succeeded_with_review"}:
            raise Conflict("DIAGNOSTICS_NOT_AVAILABLE", "Diagnostics are available only for failed or review jobs.")
        now = self.clock()
        if now >= job.get("result_expires_at", 0):
            raise Gone("Alignment diagnostics have expired.")
        remaining = job["result_expires_at"] - now
        values = {}
        for name, artifact in job.get("diagnostic_artifacts", {}).items():
            values[name] = self.storage.download_url(artifact["key"], artifact["version_id"], remaining)
        return {"job_id": job_id, "diagnostics": values,
                "url_expires_at": iso8601(now + min(900, remaining))}

    def cancel(self, job_id: str, body: Any, authorization: str | None) -> dict[str, Any]:
        if body not in ({}, None):
            raise AlignmentError("INVALID_PARAMETER", "Cancel request must have an empty JSON object.")
        job = self._authorized_job(job_id, authorization)
        prior = job["status"]
        job = self.repository.request_cancel(job, self.clock())
        if prior not in {"succeeded", "succeeded_with_review", "failed", "cancelled"}:
            if job.get("execution_arn"):
                try:
                    self.workflow.stop_execution(job["execution_arn"])
                except Exception:
                    pass
            if job.get("task_arn"):
                try:
                    self.workflow.stop_task(job["task_arn"])
                except Exception:
                    pass
        return self._status_response(job)
