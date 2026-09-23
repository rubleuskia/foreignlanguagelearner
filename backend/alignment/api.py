"""API Gateway HTTP API Lambda entry point."""
from __future__ import annotations

import json
import os
from typing import Any

from .aws_adapters import S3Store, Workflow
from .config import Config
from .errors import AlignmentError
from .repository import DynamoRepository
from .service import AlignmentService


_service: AlignmentService | None = None


def build_service() -> AlignmentService:
    import boto3

    config = Config.from_env()
    return AlignmentService(
        DynamoRepository(boto3.client("dynamodb"), config.table_name),
        S3Store(boto3.client("s3"), config.bucket_name),
        Workflow(boto3.client("stepfunctions"), boto3.client("ecs"),
                 config.state_machine_arn, config.cluster_arn),
        bucket=config.bucket_name,
        state_machine_arn=config.state_machine_arn,
        accept_new_jobs=config.accept_new_jobs,
    )


def _response(status: int, body: dict[str, Any], headers: dict[str, str] | None = None) -> dict[str, Any]:
    return {"statusCode": status, "headers": {"content-type": "application/json", **(headers or {})},
            "body": json.dumps(body, separators=(",", ":"))}


def _body(event: dict[str, Any]) -> Any:
    raw = event.get("body")
    if raw in (None, ""):
        return None
    try:
        return json.loads(raw)
    except (ValueError, TypeError) as error:
        raise AlignmentError("INVALID_JSON", "Request body must be valid JSON.") from error


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    global _service
    if _service is None:
        _service = build_service()
    request = event.get("requestContext", {}).get("http", {})
    method = request.get("method", "")
    path = request.get("path", "")
    headers = {k.lower(): v for k, v in event.get("headers", {}).items()}
    authorization = headers.get("authorization")
    job_id = event.get("pathParameters", {}).get("id")
    try:
        if method == "POST" and path == "/v1/alignments":
            status, value = _service.create(_body(event), authorization, headers.get("idempotency-key"))
            return _response(status, value)
        if not job_id:
            raise AlignmentError("NOT_FOUND", "Endpoint was not found.", 404)
        suffix = path.removeprefix(f"/v1/alignments/{job_id}")
        routes = {
            ("POST", "/upload-urls"): lambda: _service.upload_urls(job_id, _body(event), authorization),
            ("GET", "/upload"): lambda: _service.upload_status(job_id, authorization),
            ("POST", "/complete-upload"): lambda: _service.complete_upload(job_id, _body(event), authorization),
            ("POST", "/start"): lambda: _service.start(job_id, _body(event), authorization),
            ("GET", ""): lambda: _service.status(job_id, authorization),
            ("GET", "/result"): lambda: _service.result(job_id, authorization),
            ("GET", "/diagnostics"): lambda: _service.diagnostics(job_id, authorization),
            ("POST", "/cancel"): lambda: _service.cancel(job_id, _body(event), authorization),
        }
        action = routes.get((method, suffix))
        if not action:
            raise AlignmentError("NOT_FOUND", "Endpoint was not found.", 404)
        result = action()
        return _response(202 if method == "POST" and suffix in {"/start", "/cancel"} else 200, result)
    except AlignmentError as error:
        payload: dict[str, Any] = {"error": {"code": error.code, "message": error.message}}
        if job_id:
            payload["job_id"] = job_id
        extra = {"retry-after": str(error.retry_after)} if error.retry_after else None
        return _response(error.status, payload, extra)
    except Exception:
        # Raw exceptions may contain input paths/text. Keep them out of API and ordinary logs.
        payload = {"error": {"code": "INFRASTRUCTURE_FAILURE", "message": "Alignment service failed."}}
        if job_id:
            payload["job_id"] = job_id
        return _response(500, payload)
