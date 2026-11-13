"""Replay-safe DynamoDB Stream outbox. Queue bodies contain trusted S3 identity only."""
import json
import os
import time
from boto3.dynamodb.conditions import Key
from boto3.dynamodb.types import TypeDeserializer

_client = None


def handler(event, context):
    global _client
    if _client is None:
        import boto3
        from botocore.config import Config
        _client = boto3.client('sqs', config=Config(connect_timeout=3, read_timeout=5,
            retries={'total_max_attempts': 3, 'mode': 'standard'}))
    decoder = TypeDeserializer()
    if event.get('source') == 'aws.events':
        import boto3
        table = boto3.resource('dynamodb').Table(os.environ['BOOK_ALIGNMENT_TABLE'])
        # Sparse index contains only runnable work and expired worker leases.
        params = dict(IndexName='Recovery', KeyConditionExpression=Key('dispatch_state').eq('active') &
                      Key('ready_at').lte(int(time.time())), Limit=100)
        while True:
            page = table.query(**params)
            for row in page.get('Items', []):
                send(row)
            if not page.get('LastEvaluatedKey'):
                break
            params['ExclusiveStartKey'] = page['LastEvaluatedKey']
        return {}
    failures = []
    for record in event['Records']:
        try:
            images = record.get('dynamodb', {})
            row = {k: decoder.deserialize(v) for k, v in images.get('NewImage', {}).items()}
            old = images.get('OldImage', {}).get('status', {}).get('S')
            if row.get('status') != 'queued' or old == 'queued':
                continue
            send(row)
        except Exception:
            failures.append({'itemIdentifier': record['dynamodb']['SequenceNumber']})
    return {'batchItemFailures': failures}


def send(row):
    _client.send_message(QueueUrl=os.environ['BOOK_ALIGNMENT_QUEUE'], MessageBody=json.dumps({
        'owner': row['owner'], 'job_id': row['job_id'], 'bucket': os.environ['BOOK_ALIGNMENT_BUCKET'],
        'key': f"books/{row['owner']}/{row['job_id']}/input.zip", 'version_id': row['input_version']}))
