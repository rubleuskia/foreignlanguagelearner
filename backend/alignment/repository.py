"""DynamoDB single-table repository with conditional state and quota writes."""
from __future__ import annotations

from copy import deepcopy
from typing import Any

from .domain import ACTIVE_STATUSES, TERMINAL_STATUSES, seconds_until_utc_reset, utc_day
from .errors import Conflict, RateLimited


def job_key(job_id: str) -> dict[str, str]:
    return {"pk": f"JOB#{job_id}", "sk": "METADATA"}


class DynamoRepository:
    """Uses the low-level DynamoDB client so transactions serialize unambiguously."""

    def __init__(self, client: Any, table_name: str):
        self.client = client
        self.table_name = table_name

    @staticmethod
    def _s(value: str) -> dict[str, str]:
        return {"S": value}

    @staticmethod
    def _n(value: int) -> dict[str, str]:
        return {"N": str(value)}

    @classmethod
    def _encode(cls, value: Any) -> dict[str, Any]:
        if value is None:
            return {"NULL": True}
        if isinstance(value, bool):
            return {"BOOL": value}
        if isinstance(value, str):
            return cls._s(value)
        if isinstance(value, int):
            return cls._n(value)
        if isinstance(value, list):
            return {"L": [cls._encode(v) for v in value]}
        if isinstance(value, dict):
            return {"M": {k: cls._encode(v) for k, v in value.items()}}
        raise TypeError(f"Cannot encode {type(value).__name__}")

    @classmethod
    def _decode(cls, value: dict[str, Any]) -> Any:
        if "S" in value:
            return value["S"]
        if "N" in value:
            return int(value["N"])
        if "BOOL" in value:
            return value["BOOL"]
        if "NULL" in value:
            return None
        if "L" in value:
            return [cls._decode(v) for v in value["L"]]
        if "M" in value:
            return {k: cls._decode(v) for k, v in value["M"].items()}
        raise TypeError("Unknown DynamoDB value")

    @classmethod
    def _item(cls, value: dict[str, Any]) -> dict[str, Any]:
        return {k: cls._encode(v) for k, v in value.items()}

    @classmethod
    def _decoded_item(cls, value: dict[str, Any] | None) -> dict[str, Any] | None:
        return None if not value else {k: cls._decode(v) for k, v in value.items()}

    def get_job(self, job_id: str, consistent: bool = True) -> dict[str, Any] | None:
        response = self.client.get_item(
            TableName=self.table_name,
            Key=self._item(job_key(job_id)),
            ConsistentRead=consistent,
        )
        return self._decoded_item(response.get("Item"))

    def get_idempotency(self, token_hash: str, key: str) -> dict[str, Any] | None:
        response = self.client.get_item(
            TableName=self.table_name,
            Key=self._item({"pk": f"IDEMP#{token_hash}", "sk": key}),
            ConsistentRead=True,
        )
        return self._decoded_item(response.get("Item"))

    def get_token_binding(self, token_hash: str) -> dict[str, Any] | None:
        response = self.client.get_item(
            TableName=self.table_name,
            Key=self._item({"pk": f"TOKEN#{token_hash}", "sk": "BINDING"}),
            ConsistentRead=True,
        )
        return self._decoded_item(response.get("Item"))

    def _counter(self, pk: str) -> int:
        response = self.client.get_item(
            TableName=self.table_name, Key=self._item({"pk": pk, "sk": "VALUE"}),
            ConsistentRead=True, ProjectionExpression="#count",
            ExpressionAttributeNames={"#count": "count"},
        )
        item = self._decoded_item(response.get("Item"))
        return int(item.get("count", 0)) if item else 0

    def create_job(self, job: dict[str, Any], idem_key: str, body_hash: str, now: int) -> None:
        day = utc_day(now)
        idem = {"pk": f"IDEMP#{job['access_token_hash']}", "sk": idem_key,
                "job_id": job["job_id"], "request_hash": body_hash,
                "delete_after": job["delete_after"]}
        try:
            self.client.transact_write_items(TransactItems=[
            {"Put": {"TableName": self.table_name, "Item": self._item(job),
                     "ConditionExpression": "attribute_not_exists(pk)"}},
            {"Put": {"TableName": self.table_name, "Item": self._item(idem),
                     "ConditionExpression": "attribute_not_exists(pk)"}},
            {"Put": {"TableName": self.table_name,
                     "Item": self._item({"pk": f"TOKEN#{job['access_token_hash']}", "sk": "BINDING",
                                         "idempotency_key": idem_key, "job_id": job["job_id"],
                                         "delete_after": job["delete_after"]}),
                     "ConditionExpression": "attribute_not_exists(pk)"}},
            {"Update": {"TableName": self.table_name,
                        "Key": self._item({"pk": f"COUNTER#JOBS#{day}", "sk": "VALUE"}),
                        "UpdateExpression": "ADD #count :one SET delete_after = :ttl",
                        "ConditionExpression": "attribute_not_exists(#count) OR #count < :limit",
                        "ExpressionAttributeNames": {"#count": "count"},
                        "ExpressionAttributeValues": {":one": self._n(1), ":limit": self._n(20),
                                                      ":ttl": self._n(job["delete_after"])} }},
            {"Update": {"TableName": self.table_name,
                        "Key": self._item({"pk": "COUNTER#UPLOADS", "sk": "VALUE"}),
                        "UpdateExpression": "ADD #count :one",
                        "ConditionExpression": "attribute_not_exists(#count) OR #count < :limit",
                        "ExpressionAttributeNames": {"#count": "count"},
                        "ExpressionAttributeValues": {":one": self._n(1), ":limit": self._n(20)}}},
            ])
        except self.client.exceptions.TransactionCanceledException:
            if self.get_token_binding(job["access_token_hash"]):
                raise Conflict("TOKEN_ALREADY_USED", "A job capability may authorize only one job.")
            if self._counter(f"COUNTER#JOBS#{day}") >= 20:
                raise RateLimited("DAILY_JOB_LIMIT", "Daily job limit reached.", seconds_until_utc_reset(now))
            if self._counter("COUNTER#UPLOADS") >= 20:
                raise RateLimited("UPLOAD_CAPACITY", "Upload capacity is full.", 60)
            raise Conflict("CREATE_CONFLICT", "Job creation conflicted with another request.")

    def set_upload_complete(self, job: dict[str, Any], *, audio_version: str, text_version: str,
                            completed_parts: list[dict[str, Any]], now: int) -> dict[str, Any]:
        revision = job["revision"]
        self.client.update_item(
            TableName=self.table_name,
            Key=self._item(job_key(job["job_id"])),
            UpdateExpression="SET audio_version_id=:av, text_version_id=:tv, completed_parts=:parts, "
                             "upload_complete=:yes, updated_at=:now, revision=:next",
            ConditionExpression="#status=:awaiting AND revision=:revision AND attribute_not_exists(audio_version_id)",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues=self._item({":av": audio_version, ":tv": text_version,
                                                  ":parts": completed_parts, ":yes": True, ":now": now,
                                                  ":next": revision + 1, ":awaiting": "awaiting_upload",
                                                  ":revision": revision}),
        )
        return self.get_job(job["job_id"])

    def acquire_start(self, job: dict[str, Any], execution_input: str, execution_name: str,
                      state_machine_version_arn: str, now: int) -> dict[str, Any]:
        day = utc_day(now)
        revision = job["revision"]
        try:
            self.client.transact_write_items(TransactItems=[
            {"Update": {"TableName": self.table_name, "Key": self._item(job_key(job["job_id"])),
                        "UpdateExpression": "SET #status=:starting, revision=:next, updated_at=:now, "
                                            "start_requested_at=:now, execution_name=:name, "
                            "canonical_execution_input=:input, state_machine_version_arn=:version, "
                                            "admission_day=:day, upload_slot_released=:yes, admission_released=:no",
                        "ConditionExpression": "#status=:awaiting AND revision=:revision AND upload_complete=:yes",
                        "ExpressionAttributeNames": {"#status": "status"},
                        "ExpressionAttributeValues": self._item({":starting": "starting", ":awaiting": "awaiting_upload",
                            ":revision": revision, ":next": revision + 1, ":now": now, ":name": execution_name,
                            ":input": execution_input, ":version": state_machine_version_arn, ":day": day,
                            ":yes": True, ":no": False})}},
            {"Update": {"TableName": self.table_name,
                        "Key": self._item({"pk": "COUNTER#ACTIVE", "sk": "VALUE"}),
                        "UpdateExpression": "ADD #count :one",
                        "ConditionExpression": "attribute_not_exists(#count) OR #count < :limit",
                        "ExpressionAttributeNames": {"#count": "count"},
                        "ExpressionAttributeValues": {":one": self._n(1), ":limit": self._n(2)}}},
            {"Update": {"TableName": self.table_name,
                        "Key": self._item({"pk": f"COUNTER#STARTS#{day}", "sk": "VALUE"}),
                        "UpdateExpression": "ADD #count :one SET delete_after=:ttl",
                        "ConditionExpression": "attribute_not_exists(#count) OR #count < :limit",
                        "ExpressionAttributeNames": {"#count": "count"},
                        "ExpressionAttributeValues": {":one": self._n(1), ":limit": self._n(10),
                                                      ":ttl": self._n(job["delete_after"])}}},
            {"Update": {"TableName": self.table_name,
                        "Key": self._item({"pk": "COUNTER#UPLOADS", "sk": "VALUE"}),
                        "UpdateExpression": "ADD #count :minus",
                        "ConditionExpression": "#count > :zero",
                        "ExpressionAttributeNames": {"#count": "count"},
                        "ExpressionAttributeValues": {":minus": self._n(-1), ":zero": self._n(0)}}},
            ])
        except self.client.exceptions.TransactionCanceledException:
            if self._counter("COUNTER#ACTIVE") >= 2:
                raise RateLimited("ACTIVE_CAPACITY", "Processing capacity is full.", 60)
            if self._counter(f"COUNTER#STARTS#{day}") >= 10:
                raise RateLimited("DAILY_START_LIMIT", "Daily start limit reached.", seconds_until_utc_reset(now))
            raise Conflict("INVALID_STATE", "Job cannot start from its current state.")
        return self.get_job(job["job_id"])

    def set_execution_arn(self, job: dict[str, Any], arn: str, now: int) -> dict[str, Any]:
        self.client.update_item(
            TableName=self.table_name,
            Key=self._item(job_key(job["job_id"])),
            UpdateExpression="SET execution_arn=if_not_exists(execution_arn,:arn), updated_at=:now",
            ConditionExpression="#status=:starting AND execution_name=:name",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues=self._item({":arn": arn, ":now": now, ":starting": "starting",
                                                  ":name": job["execution_name"]}),
        )
        return self.get_job(job["job_id"])

    def claim_worker(self, job_id: str, task_arn: str, now: int) -> bool:
        try:
            self.client.update_item(
                TableName=self.table_name, Key=self._item(job_key(job_id)),
                UpdateExpression="SET #status=:running, task_arn=:task, worker_claimed_at=:now, "
                                 "updated_at=:now ADD revision :one",
                ConditionExpression="#status=:starting AND attribute_not_exists(worker_claimed_at)",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues=self._item({":running": "running", ":starting": "starting",
                                                      ":task": task_arn, ":now": now, ":one": 1}),
            )
            return True
        except self.client.exceptions.ConditionalCheckFailedException:
            return False

    def set_stage(self, job_id: str, stage: str, now: int) -> None:
        self.client.update_item(
            TableName=self.table_name, Key=self._item(job_key(job_id)),
            UpdateExpression="SET result_stage=:stage, updated_at=:now",
            ConditionExpression="#status=:running",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues=self._item({":stage": stage, ":now": now, ":running": "running"}),
        )

    def record_worker_output(self, job_id: str, *, manifest_key: str | None = None,
                             manifest_version_id: str | None = None,
                             outcome_key: str | None = None,
                             outcome_version_id: str | None = None, now: int) -> None:
        supplied = {"manifest_key": manifest_key, "manifest_version_id": manifest_version_id,
                    "worker_outcome_key": outcome_key, "worker_outcome_version_id": outcome_version_id}
        supplied = {name: value for name, value in supplied.items() if value is not None}
        if not supplied or (bool(manifest_key) != bool(manifest_version_id)) or (bool(outcome_key) != bool(outcome_version_id)):
            raise ValueError("Worker output requires a complete manifest or outcome pointer")
        assignments = [f"{name}=:{name}" for name in supplied]
        assignments.append("updated_at=:now")
        values = {f":{name}": value for name, value in supplied.items()}
        values.update({":now": now, ":running": "running"})
        self.client.update_item(
            TableName=self.table_name, Key=self._item(job_key(job_id)),
            UpdateExpression="SET " + ", ".join(assignments),
            ConditionExpression="#status=:running",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues=self._item(values),
        )

    def request_cancel(self, job: dict[str, Any], now: int) -> dict[str, Any]:
        if job["status"] in TERMINAL_STATUSES or job["status"] == "cancelling":
            return job
        if job["status"] not in {"awaiting_upload", "starting", "running"}:
            raise Conflict("INVALID_STATE", "Job cannot be cancelled from its current state.")
        values = {":cancelling": "cancelling", ":expected": job["status"],
                  ":revision": job["revision"], ":now": now, ":one": 1, ":yes": True}
        updates = "SET #status=:cancelling, cancel_requested_at=:now, updated_at=:now"
        transactions: list[dict[str, Any]] = []
        if job["status"] == "awaiting_upload" and not job.get("upload_slot_released", False):
            updates += ", upload_slot_released=:yes"
            transactions.append({"Update": {
                "TableName": self.table_name,
                "Key": self._item({"pk": "COUNTER#UPLOADS", "sk": "VALUE"}),
                "UpdateExpression": "ADD #count :minus",
                "ConditionExpression": "#count > :zero",
                "ExpressionAttributeNames": {"#count": "count"},
                "ExpressionAttributeValues": {":minus": self._n(-1), ":zero": self._n(0)},
            }})
        transactions.insert(0, {"Update": {
            "TableName": self.table_name, "Key": self._item(job_key(job["job_id"])),
            "UpdateExpression": updates + " ADD revision :one",
            "ConditionExpression": "#status=:expected AND revision=:revision",
            "ExpressionAttributeNames": {"#status": "status"},
            "ExpressionAttributeValues": self._item(values),
        }})
        self.client.transact_write_items(TransactItems=transactions)
        return self.get_job(job["job_id"])

    def expire_upload(self, job: dict[str, Any], now: int) -> dict[str, Any]:
        if job["status"] != "awaiting_upload":
            return job
        transactions = [{"Update": {
            "TableName": self.table_name, "Key": self._item(job_key(job["job_id"])),
            "UpdateExpression": "SET #status=:expired, updated_at=:now, completed_at=:now, "
                                "upload_slot_released=:yes, cleanup_pending=:yes ADD revision :one",
            "ConditionExpression": "#status=:awaiting AND revision=:revision AND upload_slot_released=:no",
            "ExpressionAttributeNames": {"#status": "status"},
            "ExpressionAttributeValues": self._item({":expired": "expired", ":awaiting": "awaiting_upload",
                                                      ":revision": job["revision"], ":now": now,
                                                      ":yes": True, ":no": False, ":one": 1}),
        }}, {"Update": {
            "TableName": self.table_name,
            "Key": self._item({"pk": "COUNTER#UPLOADS", "sk": "VALUE"}),
            "UpdateExpression": "ADD #count :minus",
            "ConditionExpression": "#count > :zero",
            "ExpressionAttributeNames": {"#count": "count"},
            "ExpressionAttributeValues": {":minus": self._n(-1), ":zero": self._n(0)},
        }}]
        self.client.transact_write_items(TransactItems=transactions)
        return self.get_job(job["job_id"])

    def finalize(self, job: dict[str, Any], *, status: str, now: int, error_code: str | None = None,
                 manifest: dict[str, Any] | None = None) -> dict[str, Any]:
        if job["status"] not in ACTIVE_STATUSES:
            return job
        names = {"#status": "status"}
        values: dict[str, Any] = {":status": status, ":current": job["status"], ":revision": job["revision"],
                                  ":next": job["revision"] + 1, ":now": now, ":yes": True,
                                  ":result_expiry": now + 86400, ":delete_after": now + 604800}
        sets = ["#status=:status", "revision=:next", "updated_at=:now", "completed_at=:now",
                "result_expires_at=:result_expiry", "delete_after=:delete_after",
                "admission_released=:yes", "cleanup_pending=:yes"]
        if error_code:
            sets.append("error_code=:error")
            values[":error"] = error_code
        if manifest:
            for field, value in manifest.items():
                sets.append(f"{field}=:{field}")
                values[f":{field}"] = value
        expected_release = bool(job.get("admission_released", True))
        transactions = [{"Update": {
            "TableName": self.table_name, "Key": self._item(job_key(job["job_id"])),
            "UpdateExpression": "SET " + ", ".join(sets),
            "ConditionExpression": "#status=:current AND revision=:revision AND admission_released=:expected_release",
            "ExpressionAttributeNames": names,
            "ExpressionAttributeValues": self._item({**values, ":expected_release": expected_release}),
        }}]
        if not expected_release:
            transactions.append({"Update": {
                "TableName": self.table_name,
                "Key": self._item({"pk": "COUNTER#ACTIVE", "sk": "VALUE"}),
                "UpdateExpression": "ADD #count :minus",
                "ConditionExpression": "#count > :zero",
                "ExpressionAttributeNames": {"#count": "count"},
                "ExpressionAttributeValues": {":minus": self._n(-1), ":zero": self._n(0)},
            }})
        self.client.transact_write_items(TransactItems=transactions)
        return self.get_job(job["job_id"])

    def mark_cleanup_complete(self, job: dict[str, Any], now: int) -> None:
        self.client.update_item(
            TableName=self.table_name, Key=self._item(job_key(job["job_id"])),
            UpdateExpression="SET cleanup_pending=:no, updated_at=:now",
            ConditionExpression="cleanup_pending=:yes",
            ExpressionAttributeValues=self._item({":no": False, ":yes": True, ":now": now}),
        )

    def mark_artifacts_deleted(self, job: dict[str, Any], now: int) -> None:
        self.client.update_item(
            TableName=self.table_name, Key=self._item(job_key(job["job_id"])),
            UpdateExpression="SET retained_artifacts_deleted=:yes, updated_at=:now",
            ExpressionAttributeValues=self._item({":yes": True, ":now": now}),
        )

    def scan_reconcilable(self, now: int, limit: int = 50) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        start_key = None
        for _page in range(10):
            params: dict[str, Any] = {
                "TableName": self.table_name,
                "FilterExpression": "begins_with(pk,:job) AND (#status IN (:starting,:running,:cancelling) "
                                    "OR cleanup_pending=:yes OR (#status=:awaiting AND upload_expires_at <= :now) "
                                    "OR (result_expires_at <= :now AND "
                                    "(attribute_not_exists(retained_artifacts_deleted) OR retained_artifacts_deleted=:no)))",
                "ExpressionAttributeNames": {"#status": "status"},
                "ExpressionAttributeValues": self._item({":job": "JOB#", ":starting": "starting",
                    ":running": "running", ":cancelling": "cancelling", ":awaiting": "awaiting_upload",
                    ":yes": True, ":no": False, ":now": now}),
                "Limit": limit,
            }
            if start_key:
                params["ExclusiveStartKey"] = start_key
            response = self.client.scan(**params)
            results.extend(self._decoded_item(item) for item in response.get("Items", []))
            if len(results) >= limit or not response.get("LastEvaluatedKey"):
                break
            start_key = response["LastEvaluatedKey"]
        return results[:limit]


class MemoryRepository:
    """Concurrency-shaped fake used by domain/service tests."""

    def __init__(self):
        self.jobs: dict[str, dict[str, Any]] = {}
        self.idempotency: dict[tuple[str, str], dict[str, Any]] = {}
        self.daily_jobs: dict[str, int] = {}
        self.daily_starts: dict[str, int] = {}
        self.uploads = 0
        self.active = 0
        self.token_bindings: dict[str, dict[str, Any]] = {}

    def get_job(self, job_id: str, consistent: bool = True) -> dict[str, Any] | None:
        return deepcopy(self.jobs.get(job_id))

    def get_idempotency(self, token_hash: str, key: str) -> dict[str, Any] | None:
        return deepcopy(self.idempotency.get((token_hash, key)))

    def get_token_binding(self, token_hash: str) -> dict[str, Any] | None:
        return deepcopy(self.token_bindings.get(token_hash))

    def create_job(self, job: dict[str, Any], idem_key: str, body_hash: str, now: int) -> None:
        day = utc_day(now)
        key = (job["access_token_hash"], idem_key)
        if key in self.idempotency:
            raise Conflict("IDEMPOTENCY_CONFLICT", "Idempotency key already exists.")
        if job["access_token_hash"] in self.token_bindings:
            raise Conflict("TOKEN_ALREADY_USED", "A job capability may authorize only one job.")
        if self.daily_jobs.get(day, 0) >= 20:
            raise RateLimited("DAILY_JOB_LIMIT", "Daily job limit reached.", seconds_until_utc_reset(now))
        if self.uploads >= 20:
            raise RateLimited("UPLOAD_CAPACITY", "Upload capacity is full.", 60)
        self.jobs[job["job_id"]] = deepcopy(job)
        self.idempotency[key] = {"job_id": job["job_id"], "request_hash": body_hash}
        self.token_bindings[job["access_token_hash"]] = {"job_id": job["job_id"],
                                                         "idempotency_key": idem_key}
        self.daily_jobs[day] = self.daily_jobs.get(day, 0) + 1
        self.uploads += 1

    def set_upload_complete(self, job: dict[str, Any], **updates: Any) -> dict[str, Any]:
        current = self.jobs[job["job_id"]]
        if current["status"] != "awaiting_upload" or current["revision"] != job["revision"]:
            raise Conflict("INVALID_STATE", "Upload state changed.")
        current.update(audio_version_id=updates["audio_version"], text_version_id=updates["text_version"],
                       completed_parts=deepcopy(updates["completed_parts"]), upload_complete=True,
                       updated_at=updates["now"], revision=current["revision"] + 1)
        return deepcopy(current)

    def acquire_start(self, job: dict[str, Any], execution_input: str, execution_name: str,
                      state_machine_version_arn: str, now: int) -> dict[str, Any]:
        day = utc_day(now)
        current = self.jobs[job["job_id"]]
        if self.active >= 2:
            raise RateLimited("ACTIVE_CAPACITY", "Processing capacity is full.", 60)
        if self.daily_starts.get(day, 0) >= 10:
            raise RateLimited("DAILY_START_LIMIT", "Daily start limit reached.", seconds_until_utc_reset(now))
        if current["status"] != "awaiting_upload" or not current.get("upload_complete"):
            raise Conflict("INVALID_STATE", "Upload is not complete.")
        current.update(status="starting", revision=current["revision"] + 1, updated_at=now,
                       start_requested_at=now, execution_name=execution_name,
                       canonical_execution_input=execution_input,
                       state_machine_version_arn=state_machine_version_arn,
                       admission_day=day, upload_slot_released=True, admission_released=False)
        self.active += 1
        self.uploads -= 1
        self.daily_starts[day] = self.daily_starts.get(day, 0) + 1
        return deepcopy(current)

    def set_execution_arn(self, job: dict[str, Any], arn: str, now: int) -> dict[str, Any]:
        current = self.jobs[job["job_id"]]
        current.setdefault("execution_arn", arn)
        current["updated_at"] = now
        return deepcopy(current)

    def request_cancel(self, job: dict[str, Any], now: int) -> dict[str, Any]:
        current = self.jobs[job["job_id"]]
        if current["status"] in TERMINAL_STATUSES or current["status"] == "cancelling":
            return deepcopy(current)
        if current["status"] == "awaiting_upload" and not current.get("upload_slot_released"):
            current["upload_slot_released"] = True
            self.uploads -= 1
        current.update(status="cancelling", cancel_requested_at=now, updated_at=now,
                       revision=current["revision"] + 1)
        return deepcopy(current)

    def expire_upload(self, job: dict[str, Any], now: int) -> dict[str, Any]:
        current = self.jobs[job["job_id"]]
        if current["status"] != "awaiting_upload":
            return deepcopy(current)
        if not current.get("upload_slot_released"):
            self.uploads -= 1
        current.update(status="expired", upload_slot_released=True, cleanup_pending=True,
                       completed_at=now, updated_at=now, revision=current["revision"] + 1)
        return deepcopy(current)

    def claim_worker(self, job_id: str, task_arn: str, now: int) -> bool:
        current = self.jobs[job_id]
        if current["status"] != "starting" or current.get("worker_claimed_at"):
            return False
        current.update(status="running", task_arn=task_arn, worker_claimed_at=now,
                       updated_at=now, revision=current["revision"] + 1)
        return True

    def set_stage(self, job_id: str, stage: str, now: int) -> None:
        self.jobs[job_id].update(result_stage=stage, updated_at=now)

    def record_worker_output(self, job_id: str, **values: Any) -> None:
        current = self.jobs[job_id]
        for source, target in (("manifest_key", "manifest_key"),
                               ("manifest_version_id", "manifest_version_id"),
                               ("outcome_key", "worker_outcome_key"),
                               ("outcome_version_id", "worker_outcome_version_id")):
            if values.get(source) is not None:
                current[target] = values[source]
        current["updated_at"] = values["now"]

    def finalize(self, job: dict[str, Any], *, status: str, now: int, error_code: str | None = None,
                 manifest: dict[str, Any] | None = None) -> dict[str, Any]:
        current = self.jobs[job["job_id"]]
        if current["status"] not in ACTIVE_STATUSES:
            return deepcopy(current)
        had_active_admission = not current.get("admission_released", True)
        current.update(status=status, revision=current["revision"] + 1, updated_at=now, completed_at=now,
                       result_expires_at=now + 86400, delete_after=now + 604800,
                       admission_released=True, cleanup_pending=True)
        if error_code:
            current["error_code"] = error_code
        if manifest:
            current.update(deepcopy(manifest))
        if had_active_admission and self.active:
            self.active -= 1
        current["admission_released"] = True
        return deepcopy(current)
