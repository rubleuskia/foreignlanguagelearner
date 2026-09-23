"""Pure validation and state rules shared by Lambda handlers and tests."""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import math
import re
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from .errors import AlignmentError, Conflict, Unauthorized


AUDIO_LIMIT = 1_000_000_000
TEXT_LIMIT = 10_000_000
OUTPUT_LIMIT = 10_000_000
DURATION_LIMIT = 3_600.0
PART_SIZE = 16 * 1024 * 1024
UPLOAD_TTL_SECONDS = 24 * 60 * 60
RESULT_TTL_SECONDS = 24 * 60 * 60
RECORD_TTL_SECONDS = 7 * 24 * 60 * 60
URL_TTL_SECONDS = 15 * 60
ALLOWED_LANGUAGES = frozenset({"pl"})
ALLOWED_PROFILES = frozenset({"base-guided-v1"})
ALLOWED_EXTENSIONS = frozenset({"mp3", "m4a", "wav"})
ACTIVE_STATUSES = frozenset({"starting", "running", "cancelling"})
TERMINAL_STATUSES = frozenset({"succeeded", "succeeded_with_review", "failed", "cancelled", "expired"})
ERROR_CODES = frozenset({
    "INVALID_TEXT", "INVALID_AUDIO", "INPUT_TOO_LARGE", "DURATION_LIMIT",
    "CHECKSUM_MISMATCH", "TEXT_MISMATCH", "INSUFFICIENT_ANCHORS",
    "INVALID_TIMINGS", "TIMING_OUT_OF_RANGE", "OUTPUT_TOO_LARGE",
    "WORKER_RESOURCE_LIMIT", "WORKER_TIMEOUT", "INFRASTRUCTURE_FAILURE",
})
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def epoch_now() -> int:
    return int(time.time())


def iso8601(value: int | None) -> str | None:
    if value is None:
        return None
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


def utc_day(value: int) -> str:
    return datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%d")


def seconds_until_utc_reset(value: int) -> int:
    current = datetime.fromtimestamp(value, timezone.utc)
    tomorrow = current.replace(hour=0, minute=0, second=0, microsecond=0).timestamp() + 86400
    return max(1, math.ceil(tomorrow - value))


def token_hash(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise Unauthorized()
    encoded = authorization[7:]
    if not encoded or "=" in encoded:
        raise Unauthorized()
    try:
        raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    except (ValueError, TypeError):
        raise Unauthorized()
    if len(raw) != 32 or base64.urlsafe_b64encode(raw).decode().rstrip("=") != encoded:
        raise Unauthorized()
    return hashlib.sha256(raw).hexdigest()


def capability_matches(presented_hash: str, stored_hash: str) -> bool:
    return hmac.compare_digest(presented_hash, stored_hash)


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def request_hash(value: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def _exact_fields(value: dict[str, Any], expected: set[str], label: str) -> None:
    unknown = set(value) - expected
    missing = expected - set(value)
    if unknown or missing:
        details = []
        if missing:
            details.append("missing " + ", ".join(sorted(missing)))
        if unknown:
            details.append("unknown " + ", ".join(sorted(unknown)))
        raise AlignmentError("INVALID_PARAMETER", f"Invalid {label}: {'; '.join(details)}.")


def validate_create(body: Any) -> dict[str, Any]:
    if not isinstance(body, dict):
        raise AlignmentError("INVALID_PARAMETER", "Request body must be a JSON object.")
    _exact_fields(body, {"language", "profile_id", "allow_untimed_words", "audio", "text"}, "request")
    if body["language"] not in ALLOWED_LANGUAGES:
        raise AlignmentError("INVALID_PARAMETER", "Unsupported language.")
    if body["profile_id"] not in ALLOWED_PROFILES:
        raise AlignmentError("INVALID_PARAMETER", "Unsupported alignment profile.")
    if not isinstance(body["allow_untimed_words"], bool):
        raise AlignmentError("INVALID_PARAMETER", "allow_untimed_words must be a boolean.")
    for name, fields in (("audio", {"extension", "size_bytes", "sha256"}),
                         ("text", {"size_bytes", "sha256"})):
        if not isinstance(body[name], dict):
            raise AlignmentError("INVALID_PARAMETER", f"{name} must be an object.")
        _exact_fields(body[name], fields, name)
        size = body[name]["size_bytes"]
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise AlignmentError("INVALID_PARAMETER", f"{name}.size_bytes must be a positive integer.")
        if not isinstance(body[name]["sha256"], str) or not SHA256_RE.fullmatch(body[name]["sha256"]):
            raise AlignmentError("INVALID_PARAMETER", f"{name}.sha256 must be 64 lowercase hex characters.")
    if body["audio"]["extension"] not in ALLOWED_EXTENSIONS:
        raise AlignmentError("INVALID_PARAMETER", "Unsupported audio extension.")
    if body["audio"]["size_bytes"] > AUDIO_LIMIT or body["text"]["size_bytes"] > TEXT_LIMIT:
        raise AlignmentError("INPUT_TOO_LARGE", "Declared input exceeds the public-test limit.", 413)
    return body


def validate_idempotency_key(value: str | None) -> str:
    try:
        parsed = uuid.UUID(value or "")
    except (ValueError, TypeError, AttributeError):
        raise AlignmentError("INVALID_PARAMETER", "Idempotency-Key must be a UUID.")
    if str(parsed) != value.lower():
        raise AlignmentError("INVALID_PARAMETER", "Idempotency-Key must use canonical UUID form.")
    return str(parsed)


def part_count(size: int) -> int:
    return (size + PART_SIZE - 1) // PART_SIZE


def expected_part_size(total: int, number: int) -> int:
    count = part_count(total)
    if number < 1 or number > count:
        raise AlignmentError("INVALID_PARAMETER", "Part number is outside the declared audio size.")
    return PART_SIZE if number < count else total - PART_SIZE * (count - 1)


def validate_part_numbers(body: Any, max_part: int) -> tuple[list[int], bool]:
    if not isinstance(body, dict):
        raise AlignmentError("INVALID_PARAMETER", "Request body must be a JSON object.")
    unknown = set(body) - {"part_numbers", "include_text"}
    if unknown or "part_numbers" not in body:
        raise AlignmentError("INVALID_PARAMETER", "Expected part_numbers and optional include_text only.")
    values = body["part_numbers"]
    if not isinstance(values, list) or not 1 <= len(values) <= 20:
        raise AlignmentError("INVALID_PARAMETER", "part_numbers must contain 1 to 20 values.")
    if any(isinstance(v, bool) or not isinstance(v, int) or v < 1 or v > max_part for v in values):
        raise AlignmentError("INVALID_PARAMETER", "Part number is outside the declared audio size.")
    if len(values) != len(set(values)):
        raise AlignmentError("INVALID_PARAMETER", "part_numbers must be unique.")
    include_text = body.get("include_text", False)
    if not isinstance(include_text, bool):
        raise AlignmentError("INVALID_PARAMETER", "include_text must be a boolean.")
    return values, include_text


def validate_completed_parts(body: Any, max_part: int) -> list[dict[str, Any]]:
    if not isinstance(body, dict) or set(body) != {"parts"} or not isinstance(body["parts"], list):
        raise AlignmentError("INVALID_PARAMETER", "Expected a parts array.")
    parts = body["parts"]
    if len(parts) != max_part:
        raise AlignmentError("INVALID_PARAMETER", "Every declared audio part is required.")
    result = []
    for index, item in enumerate(parts, 1):
        if not isinstance(item, dict) or set(item) != {"part_number", "etag"}:
            raise AlignmentError("INVALID_PARAMETER", "Each part requires part_number and etag.")
        if item["part_number"] != index or not isinstance(item["etag"], str) or not item["etag"].strip():
            raise AlignmentError("INVALID_PARAMETER", "Parts must be sorted, complete, and have an ETag.")
        result.append({"part_number": index, "etag": item["etag"].strip()})
    return result


ALLOWED_TRANSITIONS = {
    "awaiting_upload": {"starting", "expired", "cancelling"},
    "starting": {"running", "failed", "cancelling"},
    "running": {"succeeded", "succeeded_with_review", "failed", "cancelling"},
    "cancelling": {"cancelled"},
}


def require_transition(current: str, target: str) -> None:
    if target not in ALLOWED_TRANSITIONS.get(current, set()):
        raise Conflict("INVALID_STATE", f"Cannot change alignment from {current} to {target}.")


@dataclass(frozen=True)
class ValidatedManifest:
    key: str
    version_id: str
    requires_review: bool
    counts: dict[str, int]
    artifacts: dict[str, dict[str, Any]]


def validate_manifest(
    manifest: Any,
    *,
    job: dict[str, Any],
    manifest_key: str,
    manifest_version_id: str,
) -> ValidatedManifest:
    if not isinstance(manifest, dict):
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Worker manifest is invalid.", 500)
    required = {"schema_version", "job_id", "attempt", "profile_id", "image_digest",
                "inputs", "artifacts", "requires_review", "counts"}
    if set(manifest) != required or manifest["schema_version"] != 1 or manifest["attempt"] != 1:
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Worker manifest schema is invalid.", 500)
    if manifest["job_id"] != job["job_id"] or manifest["profile_id"] != job["profile_id"]:
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Worker manifest identity is invalid.", 500)
    if not isinstance(manifest["image_digest"], str) or not manifest["image_digest"]:
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Worker image digest is missing.", 500)
    expected_inputs = {
        "audio": {"version_id": job["audio_version_id"], "sha256": job["expected_audio_sha256"]},
        "text": {"version_id": job["text_version_id"], "sha256": job["expected_text_sha256"]},
    }
    if manifest["inputs"] != expected_inputs:
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Worker manifest input identity is invalid.", 500)
    artifacts = manifest["artifacts"]
    if not isinstance(artifacts, dict) or set(artifacts) != {"srt", "vtt", "json"}:
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Worker result set is incomplete.", 500)
    prefix = f"jobs/{job['job_id']}/attempt/1/"
    for name, artifact in artifacts.items():
        if not isinstance(artifact, dict) or set(artifact) != {"key", "version_id", "size_bytes", "sha256"}:
            raise AlignmentError("INFRASTRUCTURE_FAILURE", f"Invalid {name} artifact record.", 500)
        if not artifact["key"].startswith(prefix) or not artifact["version_id"]:
            raise AlignmentError("INFRASTRUCTURE_FAILURE", f"Invalid {name} artifact identity.", 500)
        if not isinstance(artifact["size_bytes"], int) or not 0 < artifact["size_bytes"] < OUTPUT_LIMIT:
            raise AlignmentError("OUTPUT_TOO_LARGE", f"{name} output exceeds the limit.", 500)
        if not isinstance(artifact["sha256"], str) or not SHA256_RE.fullmatch(artifact["sha256"]):
            raise AlignmentError("INFRASTRUCTURE_FAILURE", f"Invalid {name} artifact checksum.", 500)
    if not isinstance(manifest["requires_review"], bool):
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Invalid review flag.", 500)
    counts = manifest["counts"]
    if not isinstance(counts, dict) or any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in counts.values()):
        raise AlignmentError("INFRASTRUCTURE_FAILURE", "Invalid result counts.", 500)
    return ValidatedManifest(manifest_key, manifest_version_id, manifest["requires_review"], counts, artifacts)


def validate_cues(cues: Any, duration_seconds: float) -> None:
    if not isinstance(duration_seconds, (int, float)) or not math.isfinite(duration_seconds) or duration_seconds <= 0:
        raise AlignmentError("INVALID_AUDIO", "Audio duration is invalid.")
    if duration_seconds > DURATION_LIMIT:
        raise AlignmentError("DURATION_LIMIT", "Audio exceeds the 60-minute limit.")
    if not isinstance(cues, list) or not cues:
        raise AlignmentError("INVALID_TIMINGS", "Alignment produced no subtitle cues.")
    previous_end = 0.0
    for cue in cues:
        if not isinstance(cue, dict) or not {"start", "end"}.issubset(cue):
            raise AlignmentError("INVALID_TIMINGS", "Subtitle cue is malformed.")
        start, end = cue["start"], cue["end"]
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in (start, end)):
            raise AlignmentError("INVALID_TIMINGS", "Subtitle cue time is invalid.")
        # Alignment JSON stores cue timestamps in integer milliseconds.
        if start < 0 or start >= end or start < previous_end:
            raise AlignmentError("INVALID_TIMINGS", "Subtitle cues overlap or have invalid duration.")
        if end > duration_seconds * 1000 + 100:
            raise AlignmentError("TIMING_OUT_OF_RANGE", "Subtitle cue exceeds audio duration.")
        previous_end = end
