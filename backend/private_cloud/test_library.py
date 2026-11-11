import io
import json
import os
import unittest
from unittest.mock import Mock, patch
from backend.cloud.errors import CloudError
from . import api, library

BOOK = {'id': 'example', 'title': 'Example', 'language': 'pl', 'bytes': 123,
        'sha256': 'a' * 64, 'key': 'library/books/example/hash.zip'}


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, BOOK_LIBRARY_BUCKET='private-books')
        self.env.start(); self.addCleanup(self.env.stop)
        self.s3 = Mock()
        self.s3.get_object.side_effect = lambda **kw: {'Body': io.BytesIO(json.dumps({'books': [BOOK]}).encode())}
        self.s3.generate_presigned_url.return_value = 'https://private.s3.amazonaws.com/signed'

    def test_catalog_does_not_expose_storage_keys_or_urls(self):
        value = library.handle('GET /v1/library/books', {}, self.s3)
        self.assertEqual(value['books'][0]['title'], 'Example')
        self.assertNotIn('key', value['books'][0])
        self.s3.generate_presigned_url.assert_not_called()

    def test_download_is_limited_to_catalog_and_expires(self):
        for unknown in ('absent', '../example', '', 'example/other'):
            with self.assertRaises(CloudError):
                library.handle('GET /v1/library/books/{id}/download', {'id': unknown}, self.s3)
        self.s3.generate_presigned_url.assert_not_called()
        value = library.handle('GET /v1/library/books/{id}/download', {'id': 'example'}, self.s3)
        self.assertEqual(value['sha256'], BOOK['sha256'])
        self.s3.generate_presigned_url.assert_called_once_with('get_object',
            Params={'Bucket': 'private-books', 'Key': BOOK['key']}, ExpiresIn=900)

    def test_missing_object_does_not_issue_download(self):
        self.s3.head_object.side_effect = RuntimeError('Missing')
        with self.assertRaises(RuntimeError):
            library.handle('GET /v1/library/books/{id}/download', {'id': 'example'}, self.s3)
        self.s3.generate_presigned_url.assert_not_called()

    def test_authentication_precedes_catalog_read(self):
        with patch.object(api, 'runtime', return_value=(Mock(), Mock(), Mock())), \
             patch.object(api, 'authenticate', side_effect=CloudError('UNAUTHORIZED', 401)), \
             patch.object(library, 'handle') as handle:
            response = api.handler({'routeKey': 'GET /v1/library/books'}, None)
            self.assertEqual(response['statusCode'], 401)
            handle.assert_not_called()
