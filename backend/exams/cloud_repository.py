"""Owner-keyed DynamoDB storage; conditional writes are the serialization boundary."""
from __future__ import annotations

import hashlib

from .contract import ExamError, canonical


class ConcurrentWrite(Exception):
    pass


def owner_partition(owner):
    return 'OWNER#' + hashlib.sha256(owner.encode('utf-8')).hexdigest()


class CloudRepository:
    def __init__(self, table):
        self.table = table
        self.client = table.meta.client

    def get(self, pk, sk):
        return self.table.get_item(Key={'pk': pk, 'sk': sk}, ConsistentRead=True).get('Item')

    def query(self, pk, prefix):
        from boto3.dynamodb.conditions import Key
        paginator = self.client.get_paginator('query')
        for page in paginator.paginate(TableName=self.table.name,
                KeyConditionExpression=Key('pk').eq(pk) & Key('sk').begins_with(prefix),
                ConsistentRead=True):
            yield from page.get('Items', [])

    @staticmethod
    def bounded(item):
        # Conservative JSON-byte cap leaves headroom below DynamoDB's item cap.
        if len(canonical(item).encode('utf-8')) > 350 * 1024:
            raise ExamError('EXAM_RECORD_TOO_LARGE', 413)
        return item

    def new(self, item):
        from boto3.dynamodb.conditions import Attr
        try:
            self.table.put_item(Item=self.bounded(item), ConditionExpression=Attr('pk').not_exists())
        except self.client.exceptions.ConditionalCheckFailedException:
            raise ConcurrentWrite() from None

    def replace_attempt(self, item, previous_version):
        from boto3.dynamodb.conditions import Attr
        try:
            self.table.put_item(Item=self.bounded(item), ConditionExpression=(
                Attr('version').eq(previous_version) & Attr('owner').eq(item['owner'])))
        except self.client.exceptions.ConditionalCheckFailedException:
            raise ConcurrentWrite() from None

    def transaction(self, rows):
        """Each row is (item, condition); same-key operations are never duplicated."""
        from boto3.dynamodb.conditions import ConditionExpressionBuilder
        operations = []
        for item, condition in rows:
            # The resource's condition injector puts nested placeholders at the
            # operation root. Compile each condition in its own Put scope first.
            built = ConditionExpressionBuilder().build_expression(condition)
            put = {'TableName': self.table.name, 'Item': self.bounded(item),
                   'ConditionExpression': built.condition_expression}
            if built.attribute_name_placeholders:
                put['ExpressionAttributeNames'] = built.attribute_name_placeholders
            if built.attribute_value_placeholders:
                put['ExpressionAttributeValues'] = built.attribute_value_placeholders
            operations.append({'Put': put})
        try:
            self.client.transact_write_items(TransactItems=operations)
        except self.client.exceptions.TransactionCanceledException as error:
            reasons = error.response.get('CancellationReasons', [])
            if reasons and all(r.get('Code', 'None') in
                    {'None', 'ConditionalCheckFailed', 'TransactionConflict'} for r in reasons):
                raise ConcurrentWrite() from None
            raise
