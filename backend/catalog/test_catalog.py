import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import boto3
from moto import mock_aws
from backend.book_alignment.repository import Repository
from backend.cloud.errors import CloudError
from .api import handle, job_id
from .repository import Catalog
from .source import checked_url, normalize
from .processing import stage_book


def example(slug='test-book', parent=None):
    return normalize(slug, {'language': 'pol', 'title': 'Book', 'authors': [{'name': 'Author'}],
        'genres': [{'name': 'powieść kryminalna'}], 'url': 'https://wolnelektury.pl/katalog/lektura/test-book/',
        'txt': 'https://wolnelektury.pl/media/book/txt/test-book.txt', 'parent': parent,
        'media': [{'type': 'mp3', 'name': 'Chapter', 'url': 'https://wolnelektury.pl/media/book/mp3/test-book.mp3'}]})


@mock_aws
class CatalogTests(unittest.TestCase):
    def setUp(self):
        db = boto3.resource('dynamodb', region_name='eu-north-1')
        self.jobs = db.create_table(TableName='jobs', BillingMode='PAY_PER_REQUEST',
            KeySchema=[{'AttributeName': 'owner', 'KeyType': 'HASH'}, {'AttributeName': 'job_id', 'KeyType': 'RANGE'}],
            AttributeDefinitions=[{'AttributeName': x, 'AttributeType': 'S'} for x in ['owner', 'job_id']])
        table = db.create_table(TableName='catalog', BillingMode='PAY_PER_REQUEST',
            KeySchema=[{'AttributeName': 'generation', 'KeyType': 'HASH'}, {'AttributeName': 'id', 'KeyType': 'RANGE'}],
            AttributeDefinitions=[{'AttributeName': x, 'AttributeType': 'S'} for x in ['generation', 'id']])
        self.catalog = Catalog(table); self.repo = Repository(self.jobs)
        self.s3 = boto3.client('s3', region_name='eu-north-1')
        self.s3.create_bucket(Bucket='test-library', CreateBucketConfiguration={'LocationConstraint': 'eu-north-1'})
        self.s3.put_bucket_versioning(Bucket='test-library', VersioningConfiguration={'Status': 'Enabled'})
        self.book = example(); self.catalog.publish([self.book])
        self.env = patch.dict(os.environ, {'BOOK_LIBRARY_BUCKET': 'test-library'}); self.env.start(); self.addCleanup(self.env.stop)

    def call(self, route, book_id=None):
        return handle({'routeKey': route, 'pathParameters': {'id': book_id or self.book['id']}}, self.repo, self.s3, self.catalog)

    def test_duplicate_callers_share_one_job_and_progress(self):
        first = self.call('POST /v1/catalog/books/{id}/import')
        again = self.call('POST /v1/catalog/books/{id}/import')
        self.assertEqual(first['job_id'], again['job_id'])
        lease = self.repo.claim('system', first['job_id'], int(time.time()))
        self.repo.change(lease, 'aligning', 45)
        for _ in range(10):
            self.assertEqual(self.call('POST /v1/catalog/books/{id}/import')['progress'], 45)
        self.assertEqual(self.jobs.scan()['Count'], 1)
        self.assertIsNone(self.repo.claim('system', first['job_id'], int(time.time())))

    def test_new_source_version_has_distinct_job_identity(self):
        self.assertNotEqual(job_id(self.book), job_id({**self.book, 'sourceVersion': 'another'}))

    def test_failed_job_retries_but_active_job_is_not_reset(self):
        job = self.call('POST /v1/catalog/books/{id}/import')
        row = self.repo.get('system', job['job_id'])
        self.repo.change(row, 'failed', 15, error_code='INPUT_TOO_LARGE')
        retried = self.call('POST /v1/catalog/books/{id}/import')
        self.assertEqual(retried['status'], 'queued')
        self.assertEqual(retried['job_id'], job['job_id'])

    def test_persistent_result_reused_and_missing_file_regenerates(self):
        job = self.call('POST /v1/catalog/books/{id}/import'); row = self.repo.get('system', job['job_id'])
        version = self.s3.put_object(Bucket='test-library', Key='book.zip', Body=b'book')['VersionId']
        self.repo.change(row, 'succeeded', 100, result={'key': 'book.zip', 'version_id': version})
        self.assertEqual(self.call('POST /v1/catalog/books/{id}/import')['status'], 'succeeded')
        self.s3.delete_object(Bucket='test-library', Key='book.zip', VersionId=version)
        self.assertEqual(self.call('POST /v1/catalog/books/{id}/import')['status'], 'queued')

    def test_refresh_preserves_previous_generation_until_commit(self):
        old = self.catalog.active()['value']
        def stop(): raise RuntimeError('lease lost')
        with self.assertRaises(RuntimeError): self.catalog.publish([example('new-book')], stop)
        self.assertEqual(self.catalog.active()['value'], old)
        self.assertEqual(self.catalog.page()[0][0]['id'], self.book['id'])
        self.catalog.publish([example('new-book')])
        self.assertNotEqual(self.catalog.active()['value'], old)

    def test_stale_refresh_worker_cannot_publish(self):
        job = self.call('POST /v1/catalog/refresh')
        lease = self.repo.claim('system', job['job_id'], int(time.time()))
        self.catalog.publish([example('first')], guard=lambda: (self.jobs.name, lease))
        current = self.catalog.active()['value']
        self.repo.change(lease, 'failed', 50, lease_until=0)
        from botocore.exceptions import ClientError
        with self.assertRaises(ClientError):
            self.catalog.publish([example('stale')], guard=lambda: (self.jobs.name, lease))
        self.assertEqual(self.catalog.active()['value'], current)

    def test_refresh_is_shared_and_only_restarts_after_terminal(self):
        first = self.call('POST /v1/catalog/refresh'); second = self.call('POST /v1/catalog/refresh')
        self.assertEqual(first, second)
        self.assertEqual(self.repo.get('system', first['job_id'])['kind'], 'catalog_refresh')

    def test_catalog_exposes_metadata_not_source_download_internals(self):
        books = self.call('GET /v1/catalog/books')['books']
        self.assertNotIn('source', books[0]); self.assertNotIn('generation', books[0])
        self.assertIn('crime', books[0]['shelves'])
        self.assertEqual(self.call('GET /v1/catalog/books/{id}')['chapters'], ['Chapter'])

    def test_oversize_source_rejected_before_downloading(self):
        self.book['source']['validators'] = [{'bytes': 100_000_001}]
        with tempfile.TemporaryDirectory() as temp, patch('backend.catalog.source.download') as download:
            with self.assertRaisesRegex(ValueError, 'INPUT_TOO_LARGE'):
                stage_book(self.book, Path(temp), self.s3, 'test-library', Mock())
            download.assert_not_called()

    def test_source_cached_and_notices_preserved_separately(self):
        notice = '\n-----\nTa lektura, podobnie jak inne.\nLicense information'
        def download(url, path, remaining, expected):
            data = ('Book body' + notice).encode() if path.suffix == '.txt' else b'mp3'
            path.write_bytes(data); return len(data), hashlib.sha256(data).hexdigest()
        with tempfile.TemporaryDirectory() as temp, patch('backend.catalog.source.download', side_effect=download) as call:
            result = stage_book(self.book, Path(temp), self.s3, 'test-library', Mock())
            import zipfile
            with zipfile.ZipFile(result) as archive:
                self.assertEqual(archive.read('text.txt').decode(), 'Book body')
                self.assertEqual(json.loads(archive.read('provenance.json'))['originalNotices'], notice)
            self.assertEqual(call.call_count, 2)
        with tempfile.TemporaryDirectory() as temp, patch('backend.catalog.source.download') as call:
            stage_book(self.book, Path(temp), self.s3, 'test-library', Mock()); call.assert_not_called()


class SourceValidationTests(unittest.TestCase):
    def test_untrusted_addresses_never_reach_downloader(self):
        for url in ['http://wolnelektury.pl/media/book/a', 'https://evil.com/media/book/a',
            'https://wolnelektury.pl.evil.com/media/book/a', 'https://user@wolnelektury.pl/media/book/a',
            'https://wolnelektury.pl:444/media/book/a', 'https://wolnelektury.pl/media/book/../a',
            'https://wolnelektury.pl/media/book/%2e%2e/a', 'https://wolnelektury.pl/media/book/a?next=evil']:
            with self.subTest(url=url), self.assertRaises(CloudError): checked_url(url, True)


if __name__ == '__main__': unittest.main()
