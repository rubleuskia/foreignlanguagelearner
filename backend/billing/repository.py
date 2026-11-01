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
        record = {"event_id": event_id, "chain_id": chain_id, "state": "pending", "received_at": now}
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
