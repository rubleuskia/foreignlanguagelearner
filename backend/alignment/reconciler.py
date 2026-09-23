"""Scheduled crash recovery, cancellation completion, timeout, and cleanup."""
from __future__ import annotations

from typing import Any

from .aws_adapters import S3Store, Workflow
from .config import Config
from .domain import epoch_now
from .finalizer import finalize_event
from .repository import DynamoRepository


MAX_BATCH = 50
EXECUTION_TIMEOUT = 4 * 60 * 60


def _cleanup(storage: S3Store, repository: DynamoRepository, job: dict[str, Any], now: int) -> None:
    storage.delete_versions(storage.list_object_versions(f"jobs/{job['job_id']}/input/"))
    # Failed partial result artifacts are removed immediately, while private outcome and explicit
    # diagnostics remain capability-accessible until the result deadline.
    if job["status"] not in {"succeeded", "succeeded_with_review"}:
        preserved = {job.get("worker_outcome_key")}
        preserved.update(value.get("key") for value in job.get("diagnostic_artifacts", {}).values())
        partial = storage.list_object_versions(f"jobs/{job['job_id']}/attempt/1/")
        storage.delete_versions([item for item in partial if item["Key"] not in preserved])
    upload_id = job.get("multipart_upload_id")
    if upload_id and not job.get("upload_complete"):
        try:
            storage.abort_upload(job["audio_key"], upload_id)
        except Exception:
            pass
    repository.mark_cleanup_complete(job, now)


def _delete_expired_artifacts(storage: S3Store, repository: DynamoRepository,
                              job: dict[str, Any], now: int) -> None:
    storage.delete_versions(storage.list_object_versions(f"jobs/{job['job_id']}/attempt/1/"))
    repository.mark_artifacts_deleted(job, now)


def handler(_event: dict[str, Any], _context: Any) -> dict[str, Any]:
    import boto3

    config = Config.from_env()
    repository = DynamoRepository(boto3.client("dynamodb"), config.table_name)
    storage = S3Store(boto3.client("s3"), config.bucket_name)
    workflow = Workflow(boto3.client("stepfunctions"), boto3.client("ecs"),
                        config.state_machine_arn, config.cluster_arn)
    now = epoch_now()
    jobs = repository.scan_reconcilable(now, MAX_BATCH)
    repaired = 0
    for job in jobs:
        try:
            if job["status"] == "awaiting_upload" and now >= job["upload_expires_at"]:
                job = repository.expire_upload(job, now)
                repaired += 1
            if job["status"] == "starting" and not job.get("execution_arn"):
                arn = workflow.start(job["execution_name"], job["canonical_execution_input"])
                repository.set_execution_arn(job, arn, now)
                repaired += 1
                continue
            execution_status = None
            if job.get("execution_arn"):
                try:
                    execution_status = workflow.describe_execution(job["execution_arn"])["status"]
                except Exception:
                    pass
            if (job["status"] in {"starting", "running"}
                    and execution_status in {"SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"}):
                event = {"job_id": job["job_id"]}
                if execution_status == "SUCCEEDED" and job.get("manifest_key"):
                    event["worker_exit_code"] = 0
                else:
                    event["safe_failure"] = "States.Timeout" if execution_status == "TIMED_OUT" else "TaskFailure"
                finalize_event(event, repository, storage, now)
                job = repository.get_job(job["job_id"])
                repaired += 1
            overdue = now - job.get("start_requested_at", now) >= EXECUTION_TIMEOUT
            if job["status"] == "cancelling" or (job["status"] in {"starting", "running"} and overdue):
                task_arns = [job["task_arn"]] if job.get("task_arn") else workflow.list_tagged_tasks(
                    config.backend_tag, job["job_id"], limit=2
                )
                if job.get("execution_arn"):
                    try:
                        workflow.stop_execution(job["execution_arn"])
                    except Exception:
                        pass
                    try:
                        execution_status = workflow.describe_execution(job["execution_arn"])["status"]
                    except Exception:
                        execution_status = None
                for task_arn in task_arns:
                    try:
                        workflow.stop_task(task_arn)
                    except Exception:
                        pass
                execution_stopped = not job.get("execution_arn") or execution_status in {
                    "SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"
                }
                tasks_stopped = True
                for task_arn in task_arns:
                    try:
                        tasks_stopped = workflow.task_stopped(task_arn) and tasks_stopped
                    except Exception:
                        tasks_stopped = False
                if execution_stopped and tasks_stopped:
                    status = "cancelled" if job["status"] == "cancelling" else "failed"
                    code = None if status == "cancelled" else "WORKER_TIMEOUT"
                    job = repository.finalize(job, status=status, now=now, error_code=code)
                    repaired += 1
            if job.get("cleanup_pending"):
                _cleanup(storage, repository, job, now)
                repaired += 1
            if (job.get("result_expires_at", now + 1) <= now
                    and not job.get("retained_artifacts_deleted", False)):
                _delete_expired_artifacts(storage, repository, job, now)
                repaired += 1
        except Exception:
            # A later scheduled run retries. No raw exception is logged because S3 responses
            # and workflow causes are not guaranteed content-free.
            continue
    return {"examined": len(jobs), "repaired": repaired, "backlog_possible": len(jobs) == MAX_BATCH}
