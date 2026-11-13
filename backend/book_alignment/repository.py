"""Owner-keyed records, durable enqueue intent and fenced worker leases."""
import hashlib
import time
import uuid
from boto3.dynamodb.conditions import Attr, Key
from backend.cloud.errors import CloudError
from .contract import fingerprint


class Repository:
    def __init__(self, table):
        self.table = table

    def get(self, owner, job_id):
        row = self.table.get_item(Key={'owner': owner, 'job_id': job_id}, ConsistentRead=True).get('Item')
        if not row:
            raise CloudError('NOT_FOUND', 404)
        return row

    def list(self, owner, cursor=None):
        params = dict(KeyConditionExpression=Key('owner').eq(owner), Limit=50, ScanIndexForward=False,
                      ConsistentRead=True)
        if cursor:
            params['ExclusiveStartKey'] = {'owner': owner, 'job_id': cursor}
        page = self.table.query(**params)
        return page.get('Items', []), page.get('LastEvaluatedKey', {}).get('job_id')

    def create(self, owner, key, body, now):
        try:
            if str(uuid.UUID(key)) != key.lower():
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise CloudError('INVALID_IDEMPOTENCY_KEY') from None
        job_id = hashlib.sha256((owner + ':' + key.lower()).encode()).hexdigest()
        row = {'owner': owner, 'job_id': job_id, **body, 'fingerprint': fingerprint(body),
               'status': 'awaiting_upload', 'progress': 0, 'revision': 0,
               'created_at': now, 'updated_at': now, 'attempts': 0,
               'history': [{'status': 'awaiting_upload', 'at': now}]}
        try:
            self.table.put_item(Item=row, ConditionExpression=Attr('job_id').not_exists())
            return row
        except self.table.meta.client.exceptions.ConditionalCheckFailedException:
            previous = self.get(owner, job_id)
            if previous['fingerprint'] != row['fingerprint']:
                raise CloudError('IDEMPOTENCY_CONFLICT', 409) from None
            return previous

    def change(self, row, status, progress, *, extra_condition=None, **fields):
        now = int(time.time())
        next_row = {**row, **fields, 'status': status, 'progress': progress,
                    'updated_at': now, 'revision': int(row['revision']) + 1}
        if status in {'queued', 'downloading', 'preparing', 'aligning', 'validating', 'publishing'}:
            next_row.update(dispatch_state='active', ready_at=next_row.get('lease_until', 0))
        else:
            next_row.pop('dispatch_state', None)
            next_row.pop('ready_at', None)
        if status != row['status']:
            next_row['history'] = (row['history'] + [{'status': status, 'at': now}])[-100:]
        condition = Attr('revision').eq(row['revision'])
        if extra_condition is not None:
            condition &= extra_condition
        if row.get('lease_token'):
            condition &= Attr('lease_token').eq(row['lease_token'])
        try:
            self.table.put_item(Item=next_row, ConditionExpression=condition)
        except self.table.meta.client.exceptions.ConditionalCheckFailedException:
            raise CloudError('STATE_CHANGED', 409) from None
        return next_row

    def claim(self, owner, job_id, now):
        row = self.get(owner, job_id)
        if row['status'] in {'awaiting_upload', 'uploaded', 'succeeded', 'succeeded_with_review', 'failed'}:
            return None
        if row.get('lease_until', 0) > now:
            return None
        return self.change(row, 'downloading', 10, lease_token=str(uuid.uuid4()),
                           lease_until=now + 180, attempts=int(row['attempts']) + 1,
                           extra_condition=Attr('lease_until').not_exists() | Attr('lease_until').lte(now))

    def heartbeat(self, row):
        self.table.update_item(Key={'owner': row['owner'], 'job_id': row['job_id']},
            UpdateExpression='SET lease_until = :until, ready_at = :until',
            ExpressionAttributeValues={':until': int(time.time()) + 180},
            ConditionExpression=Attr('lease_token').eq(row['lease_token']) &
                                ~Attr('status').is_in(['succeeded', 'succeeded_with_review', 'failed']))


def public(row):
    names = ('job_id', 'title', 'language', 'status', 'progress', 'created_at', 'updated_at',
             'error_code', 'attempts', 'requires_review')
    return {key: int(row[key]) if key in {'progress', 'created_at', 'updated_at', 'attempts'} else row[key]
            for key in names if key in row}
