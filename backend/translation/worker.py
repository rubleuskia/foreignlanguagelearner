"""KEYS_ONLY stream -> queue; request record remains the recoverable dispatch intent."""
import json
import os
import time
import boto3
from . import runtime


def send(queue, body):
    boto3.client('sqs').send_message(QueueUrl=os.environ[queue], MessageBody=json.dumps(body))


def dispatch_handler(event, _context):
    failures = []
    for record in event.get('Records', []):
        if record.get('eventName') != 'INSERT': continue
        try: send('TRANSLATION_QUEUE_URL', {'id': record['dynamodb']['Keys']['request_id']['S']})
        except Exception: failures.append({'itemIdentifier': record['dynamodb']['SequenceNumber']})
    return {'batchItemFailures': failures}


def worker_handler(event, _context):
    # Key retrieval happens before claim. A credential outage never creates an uncertain inference.
    service = runtime.service(provider=True)
    failures = []
    for record in event.get('Records', []):
        try: service.execute(json.loads(record['body'])['id'])
        except Exception:
            print(json.dumps({'operation': 'translation_worker', 'message_id': record['messageId'], 'error': 'processing_failed'}))
            failures.append({'itemIdentifier': record['messageId']})
    return {'batchItemFailures': failures}


def maintenance_handler(event, _context):
    if 'Records' not in event:
        for kind in ['requests', 'contents']:
            send('TRANSLATION_MAINTENANCE_URL', {'kind': kind})
        return
    service = runtime.service()
    failures = []
    for record in event['Records']:
        try:
            task = json.loads(record['body'])
            kind = task['kind']
            items, cursor = (service.repo.scan_contents if kind == 'contents' else service.repo.scan)(task.get('cursor'))
            for item in items:
                if kind == 'contents':
                    if item['expires_at'] <= int(time.time()): service.repo.delete_content(item['request_id'])
                else:
                    service.maintain(item, lambda request_id: send('TRANSLATION_QUEUE_URL', {'id': request_id}))
            if cursor: send('TRANSLATION_MAINTENANCE_URL', {'kind': kind, 'cursor': cursor})
        except Exception:
            failures.append({'itemIdentifier': record['messageId']})
    return {'batchItemFailures': failures}
