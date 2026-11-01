"""Stream is the durable dispatch; scheduled reconciliation repairs missed events."""
import json
import os
import time
from . import runtime


def log_failure(operation, safe_id):
    print(json.dumps({"operation": operation, "id": safe_id, "error": "reconciliation_failed"}))


def handler(event, _context):
    service = runtime.service(with_apple=True)
    failures = []
    for record in event.get("Records", []):
        if record.get("eventName") != "INSERT":
            continue
        try:
            service.process_event(record["dynamodb"]["Keys"]["event_id"]["S"])
        except Exception:
            log_failure("billing_event", record["dynamodb"]["Keys"]["event_id"]["S"])
            # Partial batch responses keep individual failed records retryable.
            failures.append({"itemIdentifier": record["dynamodb"]["SequenceNumber"]})
    return {"batchItemFailures": failures}


def sweep_handler(event, _context):
    import boto3
    queue = boto3.client("sqs")
    def enqueue(task):
        queue.send_message(QueueUrl=os.environ["MAINTENANCE_QUEUE_URL"], MessageBody=json.dumps(task))

    if "Records" not in event:
        for kind in ("events", "subscriptions"):
            enqueue({"kind": kind})
        return
    failures = []
    for message in event["Records"]:
        try:
            task = json.loads(message["body"])
            service = runtime.service(with_apple=True)
            repo = service.repository
            if task["kind"] == "event":
                service.process_event(task["id"])
            elif task["kind"] == "chain":
                # Duplicated scheduled work need not call Apple again if already fresh.
                item = repo.subscription(task["id"])
                if item and item["verified_at"] + 1800 <= int(time.time()):
                    service.reconcile(task["id"])
            elif task["kind"] in {"events", "subscriptions"}:
                table = repo.events_table if task["kind"] == "events" else repo.subscriptions_table
                items, cursor = repo.scan_page(table, task.get("cursor"))
                for item in items:
                    if task["kind"] == "events" and item["state"] == "pending":
                        enqueue({"kind": "event", "id": item["event_id"]})
                    elif task["kind"] == "subscriptions" and item["verified_at"] + 1800 <= int(time.time()):
                        enqueue({"kind": "chain", "id": item["chain_id"]})
                if cursor:
                    enqueue({"kind": task["kind"], "cursor": cursor})
            else:
                raise ValueError("Unknown maintenance task")
        except Exception:
            log_failure("billing_maintenance", message["messageId"])
            failures.append({"itemIdentifier": message["messageId"]})
    return {"batchItemFailures": failures}
