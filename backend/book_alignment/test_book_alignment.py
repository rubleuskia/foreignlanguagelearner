import base64
import hashlib
import json
import os
import time
import unittest
import uuid
from unittest.mock import Mock, patch

import boto3
from boto3.dynamodb.types import TypeSerializer
from moto import mock_aws
from backend.cloud.errors import CloudError
from .api import handle, input_key
from .contract import ARCHIVE_LIMIT, SYSTEM_OWNER, validate_create
from .repository import Repository
from . import dispatch


@mock_aws
class BookAlignmentTests(unittest.TestCase):
    def setUp(self):
        self.ddb = boto3.resource('dynamodb', region_name='eu-north-1')
        self.table = self.ddb.create_table(TableName='books', BillingMode='PAY_PER_REQUEST',
            KeySchema=[{'AttributeName': 'owner', 'KeyType': 'HASH'}, {'AttributeName': 'job_id', 'KeyType': 'RANGE'}],
            AttributeDefinitions=[{'AttributeName': key, 'AttributeType': 'N' if key == 'ready_at' else 'S'}
                for key in ['owner', 'job_id', 'dispatch_state', 'ready_at']],
            GlobalSecondaryIndexes=[{'IndexName': 'Recovery', 'KeySchema': [
                {'AttributeName': 'dispatch_state', 'KeyType': 'HASH'}, {'AttributeName': 'ready_at', 'KeyType': 'RANGE'}],
                'Projection': {'ProjectionType': 'ALL'}}])
        self.repo = Repository(self.table)
        self.s3 = boto3.client('s3', region_name='eu-north-1')
        self.bucket = 'alignment-books-test'
        self.s3.create_bucket(Bucket=self.bucket, CreateBucketConfiguration={'LocationConstraint': 'eu-north-1'})
        self.s3.put_bucket_versioning(Bucket=self.bucket, VersioningConfiguration={'Status': 'Enabled'})
        self.payload = b'pretend zip; worker validates archive'
        self.body = {'title': 'A book', 'language': 'en', 'size_bytes': len(self.payload),
                     'sha256': hashlib.sha256(self.payload).hexdigest()}
        self.key = str(uuid.uuid4())

    def call(self, route, job_id=None, body=None):
        return handle({'routeKey': route, 'pathParameters': {'id': job_id} if job_id else {},
            'headers': {'idempotency-key': self.key}, 'body': json.dumps(body) if body else ''},
            self.repo, self.s3, self.bucket)

    def uploaded(self):
        row = self.call('POST /v1/book-alignments', body=self.body)
        stored = self.repo.get(SYSTEM_OWNER, row['job_id'])
        self.s3.put_object(Bucket=self.bucket, Key=input_key(stored), Body=self.payload,
            ChecksumAlgorithm='SHA256',
            ChecksumSHA256=base64.b64encode(hashlib.sha256(self.payload).digest()).decode())
        return self.call('POST /v1/book-alignments/{id}/complete', row['job_id'])

    def test_validate_all_languages_and_exact_limit(self):
        for language in ['en', 'fr', 'es', 'de', 'it', 'pl']:
            validate_create({**self.body, 'language': language, 'size_bytes': ARCHIVE_LIMIT})
        for value in [0, -1, True, ARCHIVE_LIMIT + 1, '123']:
            with self.assertRaises(CloudError):
                validate_create({**self.body, 'size_bytes': value})
        for field, value in [('language', 'EN'), ('owner', 'foreign'), ('sha256', 'bad')]:
            with self.assertRaises(CloudError):
                validate_create({**self.body, field: value})

    def test_create_retry_and_conflicting_payload(self):
        first = self.call('POST /v1/book-alignments', body=self.body)
        self.assertEqual(first, self.call('POST /v1/book-alignments', body=self.body))
        with self.assertRaisesRegex(CloudError, 'IDEMPOTENCY_CONFLICT'):
            self.call('POST /v1/book-alignments', body={**self.body, 'title': 'Changed'})
        self.assertEqual(len(self.call('GET /v1/book-alignments')['jobs']), 1)

    def test_upload_complete_start_are_separate_and_idempotent(self):
        uploaded = self.uploaded()
        self.assertEqual(uploaded['status'], 'uploaded')
        job_id = uploaded['job_id']
        queued = self.call('POST /v1/book-alignments/{id}/start', job_id)
        self.assertEqual(queued['status'], 'queued')
        self.assertEqual(queued, self.call('POST /v1/book-alignments/{id}/start', job_id))
        row = self.repo.get(SYSTEM_OWNER, job_id)
        self.assertTrue(row['input_version'])
        self.assertEqual(row['dispatch_state'], 'active')
        self.assertEqual([x['status'] for x in row['history']], ['awaiting_upload', 'uploaded', 'queued'])

    def test_backend_rechecks_actual_size_and_checksum(self):
        job = self.call('POST /v1/book-alignments', body=self.body)
        with patch.object(self.s3, 'head_object', return_value={'ContentLength': ARCHIVE_LIMIT + 1}):
            with self.assertRaisesRegex(CloudError, 'INPUT_TOO_LARGE'):
                self.call('POST /v1/book-alignments/{id}/complete', job['job_id'])
        with patch.object(self.s3, 'head_object', return_value={'ContentLength': self.body['size_bytes'],
                                                               'ChecksumSHA256': 'different'}):
            with self.assertRaisesRegex(CloudError, 'CHECKSUM_MISMATCH'):
                self.call('POST /v1/book-alignments/{id}/start', job['job_id'])

    def test_server_owner_and_key_cannot_be_supplied_by_client(self):
        job = self.uploaded()
        with self.assertRaisesRegex(CloudError, 'NOT_FOUND'):
            self.repo.get('another-user', job['job_id'])
        with self.assertRaisesRegex(CloudError, 'INVALID_PARAMETER'):
            self.call('POST /v1/book-alignments', body={**self.body, 'key': 'elsewhere/input.zip'})

    def test_result_is_version_pinned_serializable_and_expires_cleanly(self):
        job = self.uploaded(); job_id = job['job_id']
        row = self.repo.get(SYSTEM_OWNER, job_id)
        key = 'books/system/' + job_id + '/attempt/book.zip'
        version = self.s3.put_object(Bucket=self.bucket, Key=key, Body=b'book')['VersionId']
        self.repo.change(row, 'succeeded', 100, result={'key': key, 'version_id': version,
                                                     'bytes': 4, 'sha256': 'a' * 64})
        result = self.call('GET /v1/book-alignments/{id}/result', job_id)
        self.assertIn('versionId=' + version, result['url'])
        self.assertEqual(json.loads(json.dumps(result))['bytes'], 4)
        with patch('backend.book_alignment.api.time.time', return_value=time.time() + 31 * 86400):
            with self.assertRaisesRegex(CloudError, 'RESULT_EXPIRED'):
                self.call('GET /v1/book-alignments/{id}/result', job_id)
        self.s3.delete_object(Bucket=self.bucket, Key=key, VersionId=version)
        with self.assertRaisesRegex(CloudError, 'RESULT_EXPIRED'):
            self.call('GET /v1/book-alignments/{id}/result', job_id)

    def test_reupload_cannot_replace_confirmed_input_version(self):
        job = self.uploaded(); job_id = job['job_id']
        row = self.repo.get(SYSTEM_OWNER, job_id)
        original = row['input_version']
        self.s3.put_object(Bucket=self.bucket, Key=input_key(row), Body=b'replacement')
        self.call('POST /v1/book-alignments/{id}/start', job_id)
        self.assertEqual(self.repo.get(SYSTEM_OWNER, job_id)['input_version'], original)

    def test_duplicate_claim_and_fencing_after_recovery(self):
        job = self.uploaded(); job_id = job['job_id']
        self.call('POST /v1/book-alignments/{id}/start', job_id)
        now = int(time.time())
        first = self.repo.claim(SYSTEM_OWNER, job_id, now)
        self.assertIsNone(self.repo.claim(SYSTEM_OWNER, job_id, now + 1))
        second = self.repo.claim(SYSTEM_OWNER, job_id, now + 181)
        self.assertNotEqual(first['lease_token'], second['lease_token'])
        with self.assertRaises(CloudError):
            self.repo.change(first, 'succeeded', 100)
        self.repo.change(second, 'failed', 35, error_code='INVALID_TEXT', lease_until=0)
        row = self.repo.get(SYSTEM_OWNER, job_id)
        self.assertNotIn('dispatch_state', row)

    def test_heartbeat_prevents_stale_claim(self):
        job = self.uploaded(); job_id = job['job_id']
        self.call('POST /v1/book-alignments/{id}/start', job_id)
        now = int(time.time())
        row = self.repo.claim(SYSTEM_OWNER, job_id, now - 181)
        self.repo.heartbeat(row)
        with patch.object(self.repo, 'get', return_value=row):
            with self.assertRaisesRegex(CloudError, 'STATE_CHANGED'):
                self.repo.claim(SYSTEM_OWNER, job_id, now)

    def test_stream_dispatch_and_periodic_recovery(self):
        job = self.uploaded(); job_id = job['job_id']
        self.call('POST /v1/book-alignments/{id}/start', job_id)
        row = self.repo.get(SYSTEM_OWNER, job_id)
        serializer = TypeSerializer()
        image = {k: serializer.serialize(v) for k, v in row.items()}
        client = Mock()
        event = {'Records': [{'dynamodb': {'NewImage': image, 'OldImage': {'status': {'S': 'uploaded'}},
                                           'SequenceNumber': '1'}}]}
        with patch.object(dispatch, '_client', client), patch.dict(os.environ, {
                'BOOK_ALIGNMENT_BUCKET': self.bucket, 'BOOK_ALIGNMENT_TABLE': 'books',
                'BOOK_ALIGNMENT_QUEUE': 'https://queue', 'AWS_DEFAULT_REGION': 'eu-north-1'}):
            self.assertEqual(dispatch.handler(event, None), {'batchItemFailures': []})
            pointer = json.loads(client.send_message.call_args.kwargs['MessageBody'])
            self.assertEqual(pointer['version_id'], row['input_version'])
            dispatch.handler({'source': 'aws.events'}, None)
            self.assertEqual(client.send_message.call_count, 2)
            client.send_message.side_effect = RuntimeError()
            self.assertEqual(dispatch.handler(event, None), {'batchItemFailures': [{'itemIdentifier': '1'}]})


if __name__ == '__main__':
    unittest.main()
