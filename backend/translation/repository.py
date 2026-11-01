"""Atomic request/outbox, entitlement guards, reservations and once-only settlement."""
from backend.cloud.dynamo import encode, decode
from backend.cloud.errors import CloudError


class Repository:
    def __init__(self, client, requests, contents, usage, accounts, subscriptions):
        self.client, self.requests, self.contents, self.usage = client, requests, contents, usage
        self.accounts, self.subscriptions = accounts, subscriptions

    def get(self, table, key):
        return decode(self.client.get_item(TableName=table, Key=encode(key), ConsistentRead=True).get('Item'))

    def request(self, request_id): return self.get(self.requests, {'request_id': request_id})
    def content(self, request_id): return self.get(self.contents, {'request_id': request_id})
    def account(self, user_id): return self.get(self.accounts, {'user_id': user_id})
    def counter(self, key): return (self.get(self.usage, {'counter_id': key}) or {}).get('value', 0)

    def initialize(self, counters, now):
        for key, _ in counters:
            extra = {} if key.startswith('active:') else {':expiry': now + 90 * 86400}
            self.client.update_item(TableName=self.usage, Key=encode({'counter_id': key}),
                UpdateExpression='SET #v=if_not_exists(#v,:zero)' + (', delete_after=:expiry' if extra else ''),
                ExpressionAttributeNames={'#v': 'value'}, ExpressionAttributeValues=encode({':zero': 0, **extra}))

    def admission_items(self, record, subscription, allowance, policy, now):
        user, feature, period_id = record['user_id'], record['feature'], record['period_id']
        quota = f'quota:{user}:{feature}:{period_id}'
        release = ['active:global', f'active:{user}']
        counters = [(quota, allowance), (release[0], policy.concurrent_limit),
            (release[1], policy.per_user_concurrent), (f'minute:{user}:{now // 60}', policy.per_user_minute),
            (f'day:global:{now // 86400}', policy.daily_limit)]
        self.initialize(counters, now)
        record.update(quota_key=quota, release_keys=release, settled=False)
        items = [{'ConditionCheck': {'TableName': self.accounts, 'Key': encode({'user_id': user}),
            'ConditionExpression': '#s=:active', 'ExpressionAttributeNames': {'#s': 'state'},
            'ExpressionAttributeValues': encode({':active': 'active'})}},
            {'ConditionCheck': {'TableName': self.subscriptions, 'Key': encode({'chain_key': subscription['chain_key']}),
            'ConditionExpression': 'revision=:revision AND user_id=:owner AND access_expires_at > :now AND verified_at > :fresh',
            'ExpressionAttributeValues': encode({':revision': subscription['revision'], ':owner': user,
                ':now': now, ':fresh': now - 3600})}}]
        for key, limit in counters:
            items.append({'Update': {'TableName': self.usage, 'Key': encode({'counter_id': key}),
                'UpdateExpression': 'ADD #v :one', 'ConditionExpression': '#v < :limit',
                'ExpressionAttributeNames': {'#v': 'value'}, 'ExpressionAttributeValues': encode({':one': 1, ':limit': limit})}})
        return items

    def admit(self, record, payload, subscription, allowance, policy, now):
        items = self.admission_items(record, subscription, allowance, policy, now)
        items.extend([{'Put': {'TableName': self.requests, 'Item': encode(record),
            'ConditionExpression': 'attribute_not_exists(request_id)'}}, {'Put': {'TableName': self.contents,
            'Item': encode({'request_id': record['request_id'], 'input': payload, 'expires_at': now + 600,
                           'delete_after': now + 600})}}])
        try:
            self.client.transact_write_items(TransactItems=items)
        except self.client.exceptions.TransactionCanceledException:
            raise CloudError('ADMISSION_LIMIT', 429) from None

    def claim(self, record, now):
        try:
            self.client.transact_write_items(TransactItems=[{'Update': {
                'TableName': self.requests, 'Key': encode({'request_id': record['request_id']}),
                'UpdateExpression': 'SET #s=:running, deadline=:deadline ADD revision :one',
                'ConditionExpression': '#s=:accepted AND revision=:revision AND deadline > :now',
                'ExpressionAttributeNames': {'#s': 'state'}, 'ExpressionAttributeValues': encode({
                    ':running': 'running', ':accepted': 'accepted', ':revision': record['revision'],
                    ':deadline': now + 120, ':now': now, ':one': 1})}}, {'ConditionCheck': {
                'TableName': self.accounts, 'Key': encode({'user_id': record['user_id']}),
                'ConditionExpression': '#s=:active', 'ExpressionAttributeNames': {'#s': 'state'},
                'ExpressionAttributeValues': encode({':active': 'active'})}}])
            return self.request(record['request_id'])
        except self.client.exceptions.TransactionCanceledException:
            return None

    def settlement_items(self, record, charge):
        keys = record['release_keys'] + ([] if charge else [record['quota_key']])
        return [{'Update': {'TableName': self.usage, 'Key': encode({'counter_id': key}),
            'UpdateExpression': 'ADD #v :minus', 'ConditionExpression': '#v > :zero',
            'ExpressionAttributeNames': {'#v': 'value'}, 'ExpressionAttributeValues': encode({':minus': -1, ':zero': 0})}} for key in keys]

    def finish(self, record, state, now, result=None, tokens=None):
        if record['state'] not in {'accepted', 'running'}: return self.request(record['request_id'])
        new = {**record, 'state': state, 'settled': True, 'revision': record['revision'] + 1,
            'completed_at': now, 'result_expires_at': now + 86400, 'tokens': tokens or {}}
        items = [{'Put': {'TableName': self.requests, 'Item': encode(new),
            'ConditionExpression': 'revision=:revision AND settled=:no',
            'ExpressionAttributeValues': encode({':revision': record['revision'], ':no': False})}}]
        items += self.settlement_items(record, state == 'succeeded')
        if result is not None:
            items += [{'Put': {'TableName': self.contents, 'Item': encode({'request_id': record['request_id'],
                'result': result, 'expires_at': now + 86400, 'delete_after': now + 86400})}},
                {'ConditionCheck': {'TableName': self.accounts, 'Key': encode({'user_id': record['user_id']}),
                'ConditionExpression': '#s=:active', 'ExpressionAttributeNames': {'#s': 'state'},
                'ExpressionAttributeValues': encode({':active': 'active'})}}]
        else:
            items += [{'Delete': {'TableName': self.contents, 'Key': encode({'request_id': record['request_id']})}}]
        try:
            self.client.transact_write_items(TransactItems=items)
            return new
        except self.client.exceptions.TransactionCanceledException:
            current = self.request(record['request_id'])
            if result is not None and current and current['revision'] == record['revision'] and (self.account(record['user_id']) or {}).get('state') != 'active':
                return self.finish(record, 'cancelled', now)
            if current and current.get('settled'): return current
            raise CloudError('SETTLEMENT_CONFLICT', 503) from None

    def delete_content(self, request_id):
        self.client.delete_item(TableName=self.contents, Key=encode({'request_id': request_id}))

    def scan(self, cursor=None):
        args = {'TableName': self.requests, 'Limit': 50, 'ConsistentRead': True}
        if cursor: args['ExclusiveStartKey'] = cursor
        response = self.client.scan(**args)
        return [decode(item) for item in response.get('Items', [])], response.get('LastEvaluatedKey')

    def scan_contents(self, cursor=None):
        args = {'TableName': self.contents, 'Limit': 50, 'ConsistentRead': True,
                'ProjectionExpression': 'request_id, expires_at'}
        if cursor: args['ExclusiveStartKey'] = cursor
        response = self.client.scan(**args)
        return [decode(item) for item in response.get('Items', [])], response.get('LastEvaluatedKey')
