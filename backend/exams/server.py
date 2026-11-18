"""Loopback development API with durable storage and authenticated ranged assets.

No cloud resources, anonymous access, remote bind or provider credentials are created.
"""
import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
from urllib.parse import parse_qs, unquote, urlsplit

from backend.cloud.errors import CloudError

ROUTES = [
    ('GET', '/v1/exams'),
    ('GET', '/v1/exams/{id}/revisions/{revision}/sources/{source_id}/download'),
    ('GET', '/v1/exams/{id}/revisions/{revision}'),
    ('GET', '/v1/exams/{id}'),
    ('POST', '/v1/exam-imports/dry-run'),
    ('POST', '/v1/exam-imports/{id}/commit'),
    ('GET', '/v1/exam-attempts'),
    ('POST', '/v1/exam-attempts'),
    ('GET', '/v1/exam-attempts/{id}/assessment/{task_id}'),
    ('POST', '/v1/exam-attempts/{id}/assessment/{task_id}'),
    ('POST', '/v1/exam-attempts/{id}/submit'),
    ('GET', '/v1/exam-attempts/{id}'),
    ('PUT', '/v1/exam-attempts/{id}'),
]


def match_route(method, path):
    for verb, template in ROUTES:
        if method != verb:
            continue
        names = re.findall(r'\{(\w+)\}', template)
        pattern = re.sub(r'\{\w+\}', r'([^/]+)', template)
        match = re.fullmatch(pattern, path)
        if match:
            return f'{verb} {template}', dict(zip(names, match.groups()))
    raise CloudError('NOT_FOUND', 404)


def make_server(service, token, owner='local-pilot', port=8774):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            # Do not log headers, tokens, student answers, key material or paths.
            pass

        def reply(self, code, value):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def dispatch(self):
            try:
                if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + token):
                    raise CloudError('UNAUTHORIZED', 401)
                if self.headers.get('Origin'):
                    raise CloudError('ORIGIN_NOT_ALLOWED', 403)
                url = urlsplit(self.path)
                path = unquote(url.path)
                asset = re.fullmatch(r'/v1/exams/([^/]+)/revisions/([^/]+)/sources/([^/]+)/content', path)
                if asset and self.command == 'GET':
                    return self.asset(*asset.groups())
                route, params = match_route(self.command, path)
                body = None
                if self.command in {'POST', 'PUT'}:
                    try:
                        size = int(self.headers.get('Content-Length', '0'))
                        if not 0 < size <= 262144:
                            raise CloudError('BODY_TOO_LARGE', 413)
                        body = json.loads(self.rfile.read(size))
                    except (ValueError, UnicodeError):
                        raise CloudError('INVALID_JSON') from None
                from .api import handle
                query = {k: v[-1] for k, v in parse_qs(url.query).items()}
                self.reply(200, handle(service, route, owner, body, params, query))
            except CloudError as error:
                value = {'code': error.code}
                if getattr(error, 'details', None): value['details'] = error.details
                self.reply(error.status, {'error': value})
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception:
                self.reply(500, {'error': {'code': 'EXAM_STORAGE_FAILURE'}})

        def asset(self, exam_id, revision, source_id):
            meta = service.resolve_asset(exam_id, revision, source_id)
            file = Path(meta['path'])
            size = meta['bytes']
            start, end = 0, size - 1
            partial = self.headers.get('Range')
            if partial:
                match = re.fullmatch(r'bytes=(\d*)-(\d*)', partial)
                if not match or not any(match.groups()):
                    raise CloudError('INVALID_RANGE', 416)
                a, b = match.groups()
                if a:
                    start = int(a); end = min(int(b), end) if b else end
                else:
                    start = max(0, size - int(b))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0'); self.end_headers()
                    return
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', meta['media_type'])
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Cache-Control', 'private, no-store')
            self.send_header('ETag', '"' + meta['sha256'] + '"')
            if partial: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            with file.open('rb') as stream:
                stream.seek(start)
                left = end - start + 1
                while left:
                    chunk = stream.read(min(left, 256 * 1024))
                    if not chunk: break
                    self.wfile.write(chunk); left -= len(chunk)

        do_GET = dispatch
        do_POST = dispatch
        do_PUT = dispatch

    return ThreadingHTTPServer(('127.0.0.1', port), Handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--storage-root', required=True, type=Path)
    parser.add_argument('--port', type=int, default=8774)
    args = parser.parse_args()
    root = args.storage_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    token_file = root / '.local-api-token'
    if not token_file.exists():
        fd = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream: stream.write(secrets.token_urlsafe(32))
    token = token_file.read_text().strip()
    if len(token) < 32: parser.error('Invalid local token file')
    from .service import Service
    server = make_server(Service(root), token, port=args.port)
    print(f'Exam API: http://127.0.0.1:{args.port}; token file: {token_file}', flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()


if __name__ == '__main__': main()
