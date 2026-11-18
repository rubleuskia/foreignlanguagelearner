from contextlib import contextmanager
import http.client
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock

from .server import make_server, match_route


class LocalServerTests(unittest.TestCase):
    @contextmanager
    def running(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / 'audio.mp3'
            file.write_bytes(b'0123456789')
            service = Mock()
            service.resolve_asset.return_value = {'path': file, 'bytes': 10,
                'sha256': 'a' * 64, 'media_type': 'audio/mpeg'}
            server = make_server(service, 'test-token', port=0)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                yield server.server_address[1], service
            finally:
                server.shutdown(); server.server_close(); worker.join()

    def get(self, port, path, **headers):
        connection = http.client.HTTPConnection('127.0.0.1', port)
        connection.request('GET', path, headers=headers)
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_no_token_or_cross_origin_cannot_read_source(self):
        with self.running() as (port, service):
            path = '/v1/exams/exam/revisions/rev/sources/audio/content'
            self.assertEqual(self.get(port, path)[0], 401)
            self.assertEqual(self.get(port, path, Authorization='Bearer test-token', Origin='https://other.test')[0], 403)
            service.resolve_asset.assert_not_called()

    def test_audio_supports_precise_and_suffix_ranges(self):
        with self.running() as (port, service):
            path = '/v1/exams/exam/revisions/rev/sources/audio/content'
            for header, expected in [('bytes=2-5', b'2345'), ('bytes=-3', b'789'), ('bytes=8-', b'89')]:
                with self.subTest(header=header):
                    status, headers, data = self.get(port, path, Authorization='Bearer test-token', Range=header)
                    self.assertEqual(status, 206)
                    self.assertEqual(data, expected)
                    self.assertEqual(int(headers['Content-Length']), len(data))
            self.assertEqual(self.get(port, path, Authorization='Bearer test-token', Range='bytes=20-30')[0], 416)
            self.assertEqual(self.get(port, path, Authorization='Bearer test-token', Range='bytes=1-2,4-5')[0], 416)
            service.resolve_asset.assert_called_with('exam', 'rev', 'audio')

    def test_assessment_route_keeps_task_identity(self):
        route, params = match_route('GET', '/v1/exam-attempts/attempt/assessment/grammar-VI')
        self.assertEqual(route, 'GET /v1/exam-attempts/{id}/assessment/{task_id}')
        self.assertEqual(params, {'id': 'attempt', 'task_id': 'grammar-VI'})
