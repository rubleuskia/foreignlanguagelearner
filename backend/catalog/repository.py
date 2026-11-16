"""Publish complete metadata generations with a conditional active-pointer swap."""
import time
import uuid
from boto3.dynamodb.conditions import Key
from backend.cloud.errors import CloudError

PUBLIC = ('id', 'title', 'language', 'author', 'genres', 'shelves', 'coverURL', 'duration',
          'excerpt', 'chapterCount', 'parentID', 'parentTitle', 'sourceURL', 'sourceVersion')


def public(book):
    return {k: int(book[k]) if k == 'chapterCount' else book[k] for k in PUBLIC if k in book}


class Catalog:
    def __init__(self, table): self.table = table

    def active(self):
        return self.table.get_item(Key={'generation': 'control', 'id': 'active'}, ConsistentRead=True).get('Item')

    def page(self, generation=None, after=None):
        generation = generation or (self.active() or {}).get('value')
        if not generation: return [], None, None
        params = {'KeyConditionExpression': Key('generation').eq(generation), 'Limit': 100, 'ConsistentRead': True}
        if after: params['ExclusiveStartKey'] = {'generation': generation, 'id': after}
        result = self.table.query(**params)
        return [public(b) for b in result.get('Items', [])], result.get('LastEvaluatedKey', {}).get('id'), generation

    def get(self, book_id):
        active = self.active()
        book = self.table.get_item(Key={'generation': active['value'], 'id': book_id}, ConsistentRead=True).get('Item') if active else None
        if not book: raise CloudError('NOT_FOUND', 404)
        return book

    def publish(self, books, check=lambda: None, guard=None):
        if not books or len({b['id'] for b in books}) != len(books):
            raise CloudError('INVALID_SOURCE')
        previous = self.active()
        generation = uuid.uuid4().hex
        with self.table.batch_writer() as batch:
            for b in books:
                check()
                batch.put_item(Item={**b, 'generation': generation})
        check()
        params = {'Item': {'generation': 'control', 'id': 'active', 'value': generation,
                          'updated_at': int(time.time()), 'count': len(books)}}
        if previous:
            params.update(ConditionExpression='#v = :previous', ExpressionAttributeNames={'#v': 'value'},
                          ExpressionAttributeValues={':previous': previous['value']})
        else: params['ConditionExpression'] = 'attribute_not_exists(#v)'; params['ExpressionAttributeNames'] = {'#v': 'value'}
        if guard:
            from boto3.dynamodb.types import TypeSerializer
            import boto3
            jobs_table, row = guard()
            ser = TypeSerializer().serialize
            put = {'TableName': self.table.name, 'Item': {k: ser(v) for k,v in params['Item'].items()},
                   'ConditionExpression': params['ConditionExpression'], 'ExpressionAttributeNames': params['ExpressionAttributeNames']}
            if 'ExpressionAttributeValues' in params:
                put['ExpressionAttributeValues'] = {k: ser(v) for k,v in params['ExpressionAttributeValues'].items()}
            client = boto3.client('dynamodb', region_name=self.table.meta.client.meta.region_name)
            client.transact_write_items(TransactItems=[{'ConditionCheck': {
                'TableName': jobs_table, 'Key': {k: ser(row[k]) for k in ('owner','job_id')},
                'ConditionExpression': 'lease_token = :token AND lease_until > :now',
                'ExpressionAttributeValues': {':token': ser(row['lease_token']), ':now': ser(int(time.time()))}}}, {'Put': put}])
        else:
            self.table.put_item(**params)
        return generation
