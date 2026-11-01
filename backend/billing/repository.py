"""DynamoDB persistence. Billing records deliberately have no content TTL."""
import time
from uuid import uuid4
from backend.cloud.errors import CloudError


class DynamoRepository:
    def __init__(self, client, accounts, subscriptions, events, environment):
        from boto3.dynamodb.types import TypeSerializer, TypeDeserializer
        self.client, self.accounts_table, self.subscriptions_table, self.events_table = client, accounts, subscriptions, events
        self.environment = environment
        self.serializer, self.deserializer = TypeSerializer(), TypeDeserializer()

    def _encode(self, item):
        return {k: self.serializer.serialize(v) for k, v in item.items()}

    def _decode(self, item):
        return {k: self.deserializer.deserialize(v) for k, v in item.items()} if item else None

    def _get(self, table, key):
        return self._decode(self.client.get_item(TableName=table, Key=self._encode(key), ConsistentRead=True).get("Item"))

    def _chain_key(self, chain_id):
        return {"chain_key": f"{self.environment}#{chain_id}"}

    def account(self, user_id):
        existing = self._get(self.accounts_table, {"user_id": user_id})
        if existing:
            return existing
        account = {"user_id": user_id, "state": "active", "app_account_token": str(uuid4())}
        try:
            self.client.put_item(TableName=self.accounts_table, Item=self._encode(account),
                                 ConditionExpression="attribute_not_exists(user_id)")
            return account
        except self.client.exceptions.ConditionalCheckFailedException:
            return self._get(self.accounts_table, {"user_id": user_id})

    def bind_identity(self, user):
        account = self.account(user.user_id)
        if account['state'] == 'deleted': raise CloudError('ACCOUNT_DISABLED',403)
        if not user.apple_subject: return account
        if account['state'] == 'revoked' and user.auth_time <= account.get('valid_after',0):
            raise CloudError('SESSION_REVOKED',401)
        try:
            self.client.update_item(TableName=self.accounts_table,Key=self._encode({'user_id':user.user_id}),
                UpdateExpression='SET apple_subject=:subject, cognito_username=:username, last_auth_time=:time, #s=:active',
                ConditionExpression='#s=:expected AND (attribute_not_exists(valid_after) OR valid_after < :auth) AND (attribute_not_exists(apple_subject) OR apple_subject=:subject)',
                ExpressionAttributeNames={'#s':'state'},ExpressionAttributeValues=self._encode({':subject':user.apple_subject,
                    ':username':user.username,':time':max(user.auth_time,account.get('last_auth_time',0)),':auth':user.auth_time,
                    ':expected':account['state'],':active':'active'}))
        except self.client.exceptions.ConditionalCheckFailedException: raise CloudError('ACCOUNT_STATE_CHANGED',409) from None
        return self._get(self.accounts_table,{'user_id':user.user_id})

    def record_identity_event(self, event_id, fields, now):
        item={'event_id':event_id,'kind':'apple_identity','state':'pending','received_at':now,
              'delete_after':now+90*86400,**fields}
        try:
            self.client.put_item(TableName=self.events_table,Item=self._encode(item),ConditionExpression='attribute_not_exists(event_id)')
        except self.client.exceptions.ConditionalCheckFailedException: pass

    def apply_identity_event(self, event, now):
        if event['identity_type'] in {'email-enabled','email-disabled'}: return []
        args={'TableName':self.accounts_table,'IndexName':'AppleSubject',
              'KeyConditionExpression':'apple_subject=:subject','ExpressionAttributeValues':self._encode({':subject':event['identity_subject']})}
        users=[]
        while True:
            response=self.client.query(**args)
            users.extend(self._get(self.accounts_table,{'user_id':self._decode(item)['user_id']}) for item in response.get('Items',[]))
            if not response.get('LastEvaluatedKey'): break
            args['ExclusiveStartKey']=response['LastEvaluatedKey']
        if not users and now < event['received_at']+600: raise CloudError('IDENTITY_BINDING_PENDING',503)
        deleted=[]
        for account in users:
            if not account: continue
            permanent=event['identity_type']=='account-deleted'
            # Older consent events cannot undo a later explicit, fresh Apple sign-in.
            if not permanent and account.get('last_auth_time',0) > event['occurred_at']: continue
            try:
                when=max(event['occurred_at'],account.get('valid_after',0)) if permanent else event['occurred_at']
                condition='(attribute_not_exists(valid_after) OR valid_after = :old)' if permanent else '(attribute_not_exists(valid_after) OR valid_after <= :time) AND #s <> :deleted AND (attribute_not_exists(last_auth_time) OR last_auth_time <= :time)'
                values={':state':'deleted' if permanent else 'revoked',':time':when}
                values.update({':old':account.get('valid_after',-1)} if permanent else {':deleted':'deleted'})
                self.client.update_item(TableName=self.accounts_table,Key=self._encode({'user_id':account['user_id']}),
                    UpdateExpression='SET #s=:state, valid_after=:time',ConditionExpression=condition,
                    ExpressionAttributeNames={'#s':'state'},ExpressionAttributeValues=self._encode(values))
                if permanent and account.get('cognito_username'): deleted.append(account['cognito_username'])
            except self.client.exceptions.ConditionalCheckFailedException:
                if permanent: raise CloudError('ACCOUNT_STATE_CHANGED',503) from None
        return deleted

    def delete_event(self,event_id):
        self.client.delete_item(TableName=self.events_table,Key=self._encode({'event_id':event_id}))

    def disable_account(self, user_id):
        # Keep the tombstone and purchase ownership even if Cognito removal needs a retry.
        self.client.update_item(TableName=self.accounts_table, Key=self._encode({"user_id": user_id}),
                                UpdateExpression="SET #state = :disabled, deleted_at = if_not_exists(deleted_at, :now)",
                                ExpressionAttributeNames={"#state": "state"},
                                ExpressionAttributeValues=self._encode({":disabled": "deleted", ":now": int(time.time())}))

    def subscription(self, chain_id):
        return self._get(self.subscriptions_table, self._chain_key(chain_id))

    def subscriptions(self, account):
        records = [self.subscription(chain_id) for chain_id in sorted(account.get("chain_ids", set()))]
        return [r for r in records if r and r["user_id"] == account["user_id"]]

    def save_subscription(self, account, snapshot, previous):
        key = self._chain_key(snapshot.chain_id)
        record = {**snapshot.record(), **key, "user_id": account["user_id"],
                  "revision": int(previous["revision"]) + 1 if previous else 1}
        condition = "revision = :revision AND user_id = :owner" if previous else "attribute_not_exists(chain_key)"
        put = {"TableName": self.subscriptions_table, "Item": self._encode(record), "ConditionExpression": condition}
        if previous:
            put["ExpressionAttributeValues"] = self._encode({":revision": previous["revision"], ":owner": account["user_id"]})
        try:
            self.client.transact_write_items(TransactItems=[{"Put": put}, {"Update": {
                "TableName": self.accounts_table, "Key": self._encode({"user_id": account["user_id"]}),
                "UpdateExpression": "ADD chain_ids :chains",
                "ConditionExpression": "#state = :active AND app_account_token = :token AND (attribute_not_exists(chain_ids) OR size(chain_ids) < :limit OR contains(chain_ids, :chain))",
                "ExpressionAttributeNames": {"#state": "state"},
                "ExpressionAttributeValues": self._encode({":chains": {snapshot.chain_id}, ":active": "active",
                    ":token": account["app_account_token"], ":limit": 20, ":chain": snapshot.chain_id}),
            }}])
        except self.client.exceptions.TransactionCanceledException:
            raise CloudError("RECONCILIATION_CONFLICT", 409) from None

    def record_event(self, event_id, chain_id, now):
        record = {"event_id": event_id, "chain_id": chain_id, "state": "pending", "received_at": now, "delete_after": now + 90 * 86400}
        try:
            self.client.put_item(TableName=self.events_table, Item=self._encode(record),
                                 ConditionExpression="attribute_not_exists(event_id)")
        except self.client.exceptions.ConditionalCheckFailedException:
            pass

    def event(self, event_id):
        return self._get(self.events_table, {"event_id": event_id})

    def finish_event(self, event_id, now):
        self.client.update_item(TableName=self.events_table, Key=self._encode({"event_id": event_id}),
            UpdateExpression="SET #state = :processed, processed_at = :now",
            ExpressionAttributeNames={"#state": "state"},
            ExpressionAttributeValues=self._encode({":processed": "processed", ":now": now}))

    def scan_page(self, table, cursor=None):
        args = {"TableName": table, "Limit": 50, "ConsistentRead": True}
        if cursor:
            args["ExclusiveStartKey"] = cursor
        response = self.client.scan(**args)
        return [self._decode(item) for item in response.get("Items", [])], response.get("LastEvaluatedKey")
