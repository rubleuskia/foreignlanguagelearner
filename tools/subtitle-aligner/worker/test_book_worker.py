import hashlib
import json
from pathlib import Path
import queue
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import boto3
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import book_worker


@mock_aws
class BookWorkerTests(unittest.TestCase):
    def setUp(self):
        self.s3 = boto3.client('s3', region_name='eu-north-1')
        self.bucket = 'test-book-worker'
        self.s3.create_bucket(Bucket=self.bucket, CreateBucketConfiguration={'LocationConstraint': 'eu-north-1'})
        self.s3.put_bucket_versioning(Bucket=self.bucket, VersioningConfiguration={'Status': 'Enabled'})

    def test_compute_publishes_exact_version_hash_and_review_flag(self):
        with tempfile.TemporaryDirectory() as temp:
            result = Path(temp) / 'book.zip'; result.write_bytes(b'book package')
            messages = queue.Queue()
            with patch.object(book_worker, 'process', return_value=(result, True)), \
                    patch.dict('os.environ', {'AWS_DEFAULT_REGION': 'eu-north-1'}):
                book_worker.compute('', temp, {'bucket': self.bucket, 'result_key': 'result.zip'}, '', messages)
            self.assertEqual(messages.get(), ('stage', 'publishing', 95))
            outcome, artifact, review = messages.get()
            self.assertEqual(outcome, 'result'); self.assertTrue(review)
            self.assertEqual(artifact['sha256'], hashlib.sha256(b'book package').hexdigest())
            response = self.s3.get_object(Bucket=self.bucket, Key=artifact['key'], VersionId=artifact['version_id'])
            with response['Body'] as body:
                self.assertEqual(body.read(), b'book package')

    def test_storage_failure_is_retryable(self):
        with tempfile.TemporaryDirectory() as temp:
            result = Path(temp) / 'book.zip'; result.write_bytes(b'book')
            messages = queue.Queue()
            client = Mock(); client.put_object.side_effect = RuntimeError('temporary storage failure')
            with patch.object(book_worker, 'process', return_value=(result, False)), patch('boto3.client', return_value=client):
                book_worker.compute('', temp, {'bucket': self.bucket, 'result_key': 'result.zip'}, '', messages)
            self.assertEqual(messages.get()[0], 'stage')
            self.assertEqual(messages.get(), ('retry', 'INFRASTRUCTURE_FAILURE'))

    def test_lost_lease_terminates_compute_without_publishing_success(self):
        payload = b'input'
        key = 'books/system/job/input.zip'
        version = self.s3.put_object(Bucket=self.bucket, Key=key, Body=payload)['VersionId']
        row = {'owner': 'system', 'job_id': 'job', 'status': 'queued', 'input_version': version,
               'size_bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(),
               'title': 'Book', 'language': 'en', 'attempts': 1, 'lease_token': 'lease', 'progress': 10}
        repository = Mock(); repository.get.return_value = row; repository.claim.return_value = row
        repository.heartbeat.side_effect = RuntimeError('lease lost')
        child = Mock(); child.is_alive.side_effect = [True, False]
        context = SimpleNamespace(Queue=queue.Queue, Process=Mock(return_value=child))
        sqs = Mock()
        consumer = book_worker.Consumer(repository, self.s3, sqs, self.bucket, 'queue', '/models')
        message = {'ReceiptHandle': 'receipt', 'Body': json.dumps({'owner': 'system', 'job_id': 'job',
            'bucket': self.bucket, 'key': key, 'version_id': version})}
        with patch.object(book_worker.multiprocessing, 'get_context', return_value=context):
            with self.assertRaisesRegex(RuntimeError, 'lease lost'):
                consumer.handle(message)
        child.terminate.assert_called_once()
        repository.change.assert_not_called()
        sqs.delete_message.assert_called_once()  # Durable lease recovery replaced SQS visibility.


if __name__ == '__main__':
    unittest.main()
