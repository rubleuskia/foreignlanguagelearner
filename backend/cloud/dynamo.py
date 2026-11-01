"""Integer-only DynamoDB serialization shared by durable cloud accounting."""
from decimal import Decimal
from boto3.dynamodb.types import TypeSerializer, TypeDeserializer


def encode(value):
    return {k: TypeSerializer().serialize(v) for k, v in value.items()}


def _plain(value):
    if isinstance(value, Decimal):
        if value != int(value):
            raise ValueError('Unexpected fractional accounting value')
        return int(value)
    if isinstance(value, dict): return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list): return [_plain(v) for v in value]
    return value


def decode(value):
    return _plain({k: TypeDeserializer().deserialize(v) for k, v in value.items()}) if value else None
