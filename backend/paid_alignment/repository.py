from backend.alignment.repository import DynamoRepository
from backend.cloud.errors import CloudError
from backend.cloud.dynamo import encode
from backend.translation.policy import period


class PaidRepository(DynamoRepository):
    def __init__(self, client, table, usage, billing, policy, owner=None):
        super().__init__(client, table)
        self.usage, self.billing, self.policy, self.owner = usage, billing, policy, owner
        self.pending_admission = []

    def prepare_create(self, job, now):
        account = self.usage.account(self.owner)
        subscription, allowance = self.policy.access(account or {}, self.billing.subscriptions(account or {}), now, 'alignments')
        period_id, reset = period(now)
        reservation = {'user_id': self.owner, 'feature': 'alignments', 'period_id': period_id,
            'reset_at': reset, 'policy_version': self.policy.version}
        self.reservation_limit = allowance
        self.pending_admission = self.usage.admission_items(reservation, subscription, allowance, self.policy, now)
        job.update(owner_user_id=self.owner, paid_reservation=reservation, paid_settled=False)

    def transact(self, items, phase, job):
        if phase == 'create': items += self.pending_admission
        elif phase == 'start' and job.get('owner_user_id'):
            now = int(items[0]['Update']['ExpressionAttributeValues'][':now']['N'])
            account = self.usage.account(job['owner_user_id'])
            subscription, _ = self.policy.access(account or {}, self.billing.subscriptions(account or {}), now, 'alignments')
            items += [
                {'ConditionCheck': {'TableName': self.usage.accounts, 'Key': encode({'user_id': job['owner_user_id']}),
                    'ConditionExpression': '#s=:active', 'ExpressionAttributeNames': {'#s':'state'},
                    'ExpressionAttributeValues': encode({':active':'active'})}},
                {'ConditionCheck': {'TableName': self.usage.subscriptions, 'Key': encode({'chain_key':subscription['chain_key']}),
                    'ConditionExpression':'revision=:revision AND access_expires_at > :now AND verified_at > :fresh',
                    'ExpressionAttributeValues':encode({':revision':subscription['revision'],':now':now,':fresh':now-3600})}}]
        elif phase in {'expiry', 'finalize'} and job.get('paid_reservation'):
            update = items[0]['Update']
            expression = update['UpdateExpression']
            assignment = ', paid_settled=:paid_true'
            update['UpdateExpression'] = expression.replace(' ADD ', assignment + ' ADD ') if ' ADD ' in expression else expression + assignment
            update['ConditionExpression'] += ' AND paid_settled=:paid_false'
            update['ExpressionAttributeValues'].update(encode({':paid_true':True, ':paid_false':False}))
            status = update['ExpressionAttributeValues'].get(':status', {}).get('S')
            charge = status in {'succeeded', 'succeeded_with_review'}
            items += self.usage.settlement_items(job['paid_reservation'], charge)
            if charge:
                items.append({'ConditionCheck': {'TableName':self.usage.accounts,
                    'Key':encode({'user_id':job['owner_user_id']}), 'ConditionExpression':'#s=:active',
                    'ExpressionAttributeNames':{'#s':'state'}, 'ExpressionAttributeValues':encode({':active':'active'})}})
        try:
            self.client.transact_write_items(TransactItems=items)
        except self.client.exceptions.TransactionCanceledException:
            if phase == 'create' and (self.usage.counter(job['paid_reservation']['quota_key']) >= self.reservation_limit
                    or self.usage.counter('active:global') >= self.policy.concurrent_limit
                    or self.usage.counter(f'active:{self.owner}') >= self.policy.per_user_concurrent):
                raise CloudError('ADMISSION_LIMIT',429) from None
            raise

    def finalize(self, job, **kwargs):
        if job.get('owner_user_id') and (self.usage.account(job['owner_user_id']) or {}).get('state') != 'active':
            kwargs.update(status='cancelled', manifest=None)
        return super().finalize(job, **kwargs)

    def scan_reconcilable(self, now, limit=50):
        # Persist pagination progress: repeatedly scanning the first page can starve cleanup.
        marker_key = {'pk':'MAINTENANCE#PAID', 'sk':'CURSOR'}
        marker = self.client.get_item(TableName=self.table_name, Key=self._item(marker_key), ConsistentRead=True).get('Item')
        cursor = self._decoded_item(marker).get('cursor') if marker else None
        jobs = []
        for _ in range(10):
            params = {'TableName':self.table_name, 'Limit':limit-len(jobs),
                'FilterExpression':'begins_with(pk,:job)', 'ExpressionAttributeValues':self._item({':job':'JOB#'})}
            if cursor: params['ExclusiveStartKey'] = self._item(cursor)
            page = self.client.scan(**params)
            jobs.extend(self._decoded_item(item) for item in page.get('Items',[]))
            cursor = self._decoded_item(page.get('LastEvaluatedKey'))
            if not cursor or len(jobs) >= limit: break
        self.client.put_item(TableName=self.table_name, Item=self._item({**marker_key,'cursor':cursor}))
        return jobs
