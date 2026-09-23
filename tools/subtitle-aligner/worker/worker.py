#!/usr/bin/env python3
"""Run exactly one pinned cloud alignment attempt and publish a manifest last."""
from __future__ import annotations

import contextlib
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from typing import Any
from urllib.request import urlopen

ALIGNER_DIR = Path(__file__).resolve().parent.parent
REPOSITORY_ROOT = ALIGNER_DIR.parent.parent
sys.path.insert(0, str(REPOSITORY_ROOT))
sys.path.insert(0, str(ALIGNER_DIR))

import align  # noqa: E402
from backend.alignment.domain import (  # noqa: E402
    AUDIO_LIMIT, DURATION_LIMIT, ERROR_CODES, OUTPUT_LIMIT, TEXT_LIMIT,
    canonical_json, epoch_now, validate_cues,
)
from backend.alignment.repository import DynamoRepository  # noqa: E402


class WorkerFailure(Exception):
    def __init__(self, code: str, diagnostic_artifacts: dict[str, Any] | None = None):
        super().__init__(code)
        self.code = code
        self.diagnostic_artifacts = diagnostic_artifacts or {}


def watchdog_timeout(*_args: Any) -> None:
    raise WorkerFailure("WORKER_TIMEOUT")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def task_arn() -> str:
    if os.environ.get("ECS_TASK_ARN"):
        return os.environ["ECS_TASK_ARN"]
    endpoint = os.environ.get("ECS_CONTAINER_METADATA_URI_V4")
    if endpoint:
        try:
            with urlopen(endpoint + "/task", timeout=2) as response:
                return json.load(response)["TaskARN"]
        except Exception:
            pass
    raise WorkerFailure("INFRASTRUCTURE_FAILURE")


def probe_duration(audio: Path) -> float:
    command = ["ffprobe", "-v", "error", "-show_entries",
               "format=duration:stream=codec_type,codec_name:stream_disposition=attached_pic",
               "-of", "json", str(audio)]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True,
                                timeout=60, env={"PATH": os.environ.get("PATH", "")})
        if len(result.stdout) > 64 * 1024:
            raise WorkerFailure("INVALID_AUDIO")
        value = json.loads(result.stdout)
        streams = value.get("streams", [])
        if any(stream.get("codec_type") == "video"
               and stream.get("disposition", {}).get("attached_pic") != 1 for stream in streams):
            raise WorkerFailure("INVALID_AUDIO")
        allowed_codecs = {"mp3", "aac", "alac", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"}
        audio_streams = [stream for stream in streams if stream.get("codec_type") == "audio"]
        if not audio_streams or any(stream.get("codec_name") not in allowed_codecs for stream in audio_streams):
            raise WorkerFailure("INVALID_AUDIO")
        duration = float(value["format"]["duration"])
    except WorkerFailure:
        raise
    except Exception as error:
        raise WorkerFailure("INVALID_AUDIO") from error
    if not 0 < duration <= DURATION_LIMIT:
        raise WorkerFailure("DURATION_LIMIT" if duration > DURATION_LIMIT else "INVALID_AUDIO")
    return duration


def map_alignment_error(error: BaseException) -> str:
    message = str(error).lower()
    if "utf-8" in message or "txt is empty" in message:
        return "INVALID_TEXT"
    if "differs from input" in message:
        return "TEXT_MISMATCH"
    if "insufficient matching transcript anchors" in message:
        return "INSUFFICIENT_ANCHORS"
    if "timestamp" in message or "duration" in message or "overlap" in message:
        return "INVALID_TIMINGS"
    if "10 mb" in message or "exceed" in message:
        return "OUTPUT_TOO_LARGE"
    return "INFRASTRUCTURE_FAILURE"


class Worker:
    def __init__(self, s3: Any, repository: DynamoRepository, bucket: str, image_digest: str,
                 model_dir: Path):
        self.s3 = s3
        self.repository = repository
        self.bucket = bucket
        self.image_digest = image_digest
        self.model_dir = model_dir
        self.cancelled = False

    def cancel(self, *_args: Any) -> None:
        self.cancelled = True
        raise WorkerFailure("INFRASTRUCTURE_FAILURE")

    def download(self, specification: dict[str, Any], destination: Path, byte_limit: int) -> None:
        if specification["size_bytes"] > byte_limit:
            raise WorkerFailure("INPUT_TOO_LARGE")
        with destination.open("wb") as output:
            self.s3.download_fileobj(
                self.bucket, specification["key"], output,
                ExtraArgs={"VersionId": specification["version_id"]},
            )
        if destination.stat().st_size != specification["size_bytes"] or sha256_file(destination) != specification["sha256"]:
            raise WorkerFailure("CHECKSUM_MISMATCH")

    def upload_file(self, job_id: str, name: str, source: Path) -> dict[str, Any]:
        key = f"jobs/{job_id}/attempt/1/{name}"
        digest = sha256_file(source)
        response = self.s3.put_object(Bucket=self.bucket, Key=key, Body=source.read_bytes(),
                                      ChecksumSHA256=base64.b64encode(bytes.fromhex(digest)).decode(),
                                      ServerSideEncryption="AES256")
        return {"key": key, "version_id": response["VersionId"],
                "size_bytes": source.stat().st_size, "sha256": digest}

    def upload_json(self, job_id: str, name: str, value: dict[str, Any]) -> tuple[str, str]:
        key = f"jobs/{job_id}/attempt/1/{name}"
        response = self.s3.put_object(Bucket=self.bucket, Key=key,
                                      Body=(canonical_json(value) + "\n").encode(),
                                      ContentType="application/json", ServerSideEncryption="AES256")
        return key, response["VersionId"]

    def run(self, specification: dict[str, Any]) -> dict[str, Any]:
        job_id = specification["job_id"]
        if specification.get("schema_version") != 1 or specification.get("profile_id") != "base-guided-v1":
            raise WorkerFailure("INFRASTRUCTURE_FAILURE")
        if not self.model_dir.is_dir():
            raise WorkerFailure("INFRASTRUCTURE_FAILURE")
        if not self.repository.claim_worker(job_id, task_arn(), epoch_now()):
            # A duplicate task must not perform inference.
            return {"job_id": job_id, "worker_exit_code": 75, "duplicate_claim": True}
        started = time.monotonic()
        with tempfile.TemporaryDirectory(prefix="alignment-") as temp:
            root = Path(temp)
            audio = root / "audio.input"
            text = root / "transcript.txt"
            output = root / "output"
            private_log = root / "worker-private.log"
            self.repository.set_stage(job_id, "downloading", epoch_now())
            self.download(specification["audio"], audio, AUDIO_LIMIT)
            self.download(specification["text"], text, TEXT_LIMIT)
            duration = probe_duration(audio)
            if self.cancelled:
                raise WorkerFailure("INFRASTRUCTURE_FAILURE")
            self.repository.set_stage(job_id, "aligning", epoch_now())
            args = SimpleNamespace(
                text=text, audio=audio, alignment_json=None, output=output,
                language=specification["language"], model="base", token_step=100,
                guided=True, allow_untimed_words=specification["allow_untimed_words"],
                device="cpu", model_dir=self.model_dir, format="both", max_chars=42,
                max_duration=6.0, max_gap=0.8, offset=0.0,
            )
            try:
                with private_log.open("w", encoding="utf-8") as log, \
                     contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                    align.run(args)
            except Exception as error:
                diagnostics = {}
                for filename in ("alignment-failed.json", "normalized.txt"):
                    path = output / filename
                    if path.is_file():
                        diagnostics[filename] = self.upload_file(
                            job_id, f"diagnostics/{filename}", path
                        )
                raise WorkerFailure(map_alignment_error(error), diagnostics) from error
            if time.monotonic() - started > 3 * 60 * 60 + 45 * 60:
                raise WorkerFailure("WORKER_TIMEOUT")
            self.repository.set_stage(job_id, "validating", epoch_now())
            report = json.loads((output / "alignment.json").read_text(encoding="utf-8"))
            validate_cues(report.get("cues"), duration)
            paths = {"srt": output / "subtitles.srt", "vtt": output / "subtitles.vtt",
                     "json": output / "alignment.json"}
            if any(path.stat().st_size >= OUTPUT_LIMIT for path in paths.values()):
                raise WorkerFailure("OUTPUT_TOO_LARGE")
            self.repository.set_stage(job_id, "uploading", epoch_now())
            artifacts = {name: self.upload_file(job_id, path.name, path) for name, path in paths.items()}
            words = [word for segment in report["alignment"]["segments"] for word in segment["words"]]
            manifest = {
                "schema_version": 1, "job_id": job_id, "attempt": 1,
                "profile_id": specification["profile_id"], "image_digest": self.image_digest,
                "inputs": {
                    "audio": {"version_id": specification["audio"]["version_id"],
                              "sha256": specification["audio"]["sha256"]},
                    "text": {"version_id": specification["text"]["version_id"],
                             "sha256": specification["text"]["sha256"]},
                },
                "artifacts": artifacts, "requires_review": bool(report["requires_review"]),
                "counts": {"cues": len(report["cues"]), "words": len(words),
                           "untimed_words": len(report.get("untimed_words", [])),
                           "engine_duplicate_words": len(report["alignment"].get("engine_duplicate_words", []))},
            }
            key, version = self.upload_json(job_id, "manifest.json", manifest)
            self.repository.record_worker_output(job_id, manifest_key=key,
                                                 manifest_version_id=version, now=epoch_now())
            return {"job_id": job_id, "worker_exit_code": 0,
                    "manifest_key": key, "manifest_version_id": version}


def main() -> int:
    import boto3

    specification = json.loads(os.environ["ALIGNMENT_INPUT"])
    repository = DynamoRepository(boto3.client("dynamodb"), os.environ["ALIGNMENT_TABLE"])
    worker = Worker(boto3.client("s3"), repository, os.environ["ALIGNMENT_BUCKET"],
                    os.environ["WORKER_IMAGE_DIGEST"], Path(os.environ["MODEL_DIR"]))
    signal.signal(signal.SIGTERM, worker.cancel)
    signal.signal(signal.SIGALRM, watchdog_timeout)
    signal.setitimer(signal.ITIMER_REAL, 3 * 60 * 60 + 45 * 60)
    try:
        result = worker.run(specification)
        print(canonical_json(result))
        return 0 if result.get("worker_exit_code") == 0 else 75
    except WorkerFailure as error:
        job_id = specification.get("job_id", "unknown")
        code = error.code if error.code in ERROR_CODES else "INFRASTRUCTURE_FAILURE"
        outcome = {"schema_version": 1, "job_id": job_id, "attempt": 1, "error_code": code,
                   "diagnostic_artifacts": error.diagnostic_artifacts}
        try:
            key, version = worker.upload_json(job_id, "outcome.json", outcome)
            repository.record_worker_output(job_id, outcome_key=key,
                                            outcome_version_id=version, now=epoch_now())
            print(canonical_json({"job_id": job_id, "worker_exit_code": 1,
                                  "outcome_key": key, "outcome_version_id": version,
                                  "safe_error_code": code}))
        except Exception:
            print(canonical_json({"job_id": job_id, "worker_exit_code": 1,
                                  "safe_error_code": "INFRASTRUCTURE_FAILURE"}))
        return 1
    except Exception:
        # Do not let SDK/library exception strings reach container logs: they may include paths,
        # request metadata, or user-derived text.
        job_id = specification.get("job_id", "unknown")
        outcome = {"schema_version": 1, "job_id": job_id, "attempt": 1,
                   "error_code": "INFRASTRUCTURE_FAILURE", "diagnostic_artifacts": {}}
        try:
            key, version = worker.upload_json(job_id, "outcome.json", outcome)
            repository.record_worker_output(job_id, outcome_key=key,
                                            outcome_version_id=version, now=epoch_now())
            print(canonical_json({"job_id": job_id, "worker_exit_code": 1,
                                  "outcome_key": key, "outcome_version_id": version,
                                  "safe_error_code": "INFRASTRUCTURE_FAILURE"}))
        except Exception:
            print(canonical_json({"job_id": job_id, "worker_exit_code": 1,
                                  "safe_error_code": "INFRASTRUCTURE_FAILURE"}))
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    raise SystemExit(main())
