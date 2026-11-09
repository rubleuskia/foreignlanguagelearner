"""Atomic submission boundary and daily admission cap; no asynchronous dispatcher."""
import hashlib
import json
from backend.cloud.dynamo import encode, decode
from backend.cloud.errors import CloudError


class Repository:
    def __init__(self, client, table):
        self.client, self.table = client, table

    def get(self, key):
        return decode(self.client.get_item(TableName=self.table, Key=encode({'id': key}),
                                           ConsistentRead=True).get('Item'))

    def pin_operator(self, subject):
        try:
            self.client.put_item(TableName=self.table, Item=encode({'id': 'operator', 'subject': subject}),
                                 ConditionExpression='attribute_not_exists(id)')
        except self.client.exceptions.ConditionalCheckFailedException:
            if self.get('operator').get('subject') != subject:
                raise CloudError('OPERATOR_SUBJECT_CHANGED', 403) from None

    @staticmethod
    def request_id(owner, key):
        return hashlib.sha256((owner + ':' + key).encode()).hexdigest()

    def admit(self, owner, key, fingerprint, now, daily_limit):
        request_id = self.request_id(owner, key)
        row = {'id': request_id, 'request_id': request_id, 'owner': owner, 'fingerprint': fingerprint,
               'state': 'running', 'created_at': now, 'delete_after': now + 86400}
        try:
            self.client.transact_write_items(TransactItems=[
                {'Put': {'TableName': self.table, 'Item': encode(row),
                         'ConditionExpression': 'attribute_not_exists(id)'}},
                {'Update': {'TableName': self.table, 'Key': encode({'id': 'day:' + str(now // 86400)}),
                            'UpdateExpression': 'SET delete_after = :ttl ADD admissions :one',
                            'ConditionExpression': 'attribute_not_exists(admissions) OR admissions < :limit',
                            'ExpressionAttributeValues': encode({':ttl': now + 172800, ':one': 1, ':limit': daily_limit})}},
            ])
            return row, True
        except self.client.exceptions.TransactionCanceledException:
            previous = self.get(request_id)
            if previous:
                if previous['fingerprint'] != fingerprint:
                    raise CloudError('IDEMPOTENCY_CONFLICT', 409) from None
                return previous, False
            raise CloudError('ADMISSION_UNAVAILABLE', 429) from None

    def finish(self, row, state, result=None, tokens=None):
        values = {':running': 'running', ':state': state, ':result': json.dumps(result, ensure_ascii=False),
                  ':tokens': tokens or {}}
        self.client.update_item(TableName=self.table, Key=encode({'id': row['id']}),
            UpdateExpression='SET #s=:state, result_json=:result, token_usage=:tokens',
            ConditionExpression='#s=:running', ExpressionAttributeNames={'#s': 'state'},
            ExpressionAttributeValues=encode(values))
        return {**row, 'state': state, 'result_json': values[':result'], 'token_usage': tokens or {}}

    @staticmethod
    def public(row, now):
        if now >= row['delete_after']:
            raise CloudError('RESULT_EXPIRED', 410)
        state = row['state']
        if state == 'running' and now - row['created_at'] >= 30:
            state = 'outcome_unknown'
        value = {'schema_version': 1, 'request_id': row['request_id'], 'state': state}
        if state == 'succeeded':
            value['result'] = json.loads(row['result_json'])
        return value
