"""Loopback control server. Run with python -m tools.cloud_control.server."""
import argparse
import fcntl
import json
import os
import secrets
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from .aws import AWS, clean_error
from .config import Configuration, ControlError
from .jobs import Jobs

STATIC = Path(__file__).parent / 'web'


class Application:
    def __init__(self, root, directory):
        self.configuration = Configuration(directory)
        self.jobs = Jobs(root, self.configuration)
        self.token = secrets.token_urlsafe(32)
        self.status_lock = threading.Lock()
        self.cached_status = None
        self.status_at = 0

    def status(self):
        with self.status_lock:
            if time.monotonic() - self.status_at < 15 and self.cached_status is not None:
                return self.cached_status
            try: value = AWS(self.configuration.load()).status()
            except Exception as error:
                value = {'configured': self.configuration.path.exists(), 'available': False,
                    'error': str(error) if isinstance(error, ControlError) else
                    'Нет доступа к AWS: ' + clean_error(error) + '. Проверьте вход в локальный SSO-профиль.'}
            self.cached_status, self.status_at = value, time.monotonic()
            return value


class Handler(BaseHTTPRequestHandler):
    server_version = 'FLL-Control'

    def log_message(self, *args): pass  # No tokens or request bodies in HTTP logs.

    def send(self, status, body, content_type='application/json; charset=utf-8'):
        if not isinstance(body, bytes): body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        for key, value in {'Content-Type': content_type, 'Content-Length': str(len(body)),
            'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
            'Referrer-Policy': 'no-referrer', 'Cross-Origin-Resource-Policy': 'same-origin',
            'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"}.items():
            self.send_header(key, value)
        self.end_headers(); self.wfile.write(body)

    def host_allowed(self):
        return self.headers.get('Host') in {f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'}

    def do_GET(self):
        if not self.host_allowed(): return self.send(403, {'error': 'Недопустимый адрес панели.'})
        app = self.server.app
        try:
            if self.path == '/':
                page = (STATIC / 'index.html').read_text().replace('{{CONTROL_TOKEN}}', app.token)
                return self.send(200, page.encode(), 'text/html; charset=utf-8')
            if self.path in {'/app.js', '/style.css'}:
                kind = 'text/javascript' if self.path.endswith('.js') else 'text/css'
                return self.send(200, (STATIC / self.path[1:]).read_bytes(), kind + '; charset=utf-8')
            if self.path == '/api/status': return self.send(200, app.status())
            if self.path == '/api/readiness':
                return self.send(200, AWS(app.configuration.load()).readiness())
            if self.path == '/api/state':
                return self.send(200, {'jobs': app.jobs.list(), 'active': app.jobs.active,
                    'tags': app.jobs.releases.list(), 'configuration': app.configuration.public()})
            if self.path == '/api/profiles':
                try:
                    import boto3
                    profiles = boto3.Session().available_profiles
                except Exception: profiles = []
                return self.send(200, {'profiles': profiles})
            return self.send(404, {'error': 'Не найдено.'})
        except Exception as error:
            self.send(400, {'error': str(error) if isinstance(error, ControlError) else 'Не удалось прочитать состояние панели.'})

    def do_POST(self):
        app = self.server.app
        origins = {f'http://127.0.0.1:{self.server.server_port}', f'http://localhost:{self.server.server_port}'}
        if (not self.host_allowed() or self.headers.get('Origin') not in origins
                or not secrets.compare_digest(self.headers.get('X-Control-Token', ''), app.token)):
            return self.send(403, {'error': 'Запрос должен исходить из открытой локальной панели.'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 1 <= length <= 32768 or self.headers.get_content_type() != 'application/json':
                raise ControlError('Нужен JSON размером до 32 КБ.')
            value = json.loads(self.rfile.read(length))
            if not isinstance(value, dict): raise ControlError('Нужен JSON-объект.')
            if self.path == '/api/config':
                if not app.jobs.lock.acquire(blocking=False): raise ControlError('Дождитесь окончания текущей операции.')
                try:
                    app.configuration.save(value); app.status_at = 0
                finally: app.jobs.lock.release()
                return self.send(200, {'saved': True})
            actions = {'/api/refresh': 'refresh', '/api/prepare': 'prepare', '/api/deploy': 'deploy', '/api/tests': 'tests'}
            if self.path not in actions: return self.send(404, {'error': 'Не найдено.'})
            return self.send(202, app.jobs.start(actions[self.path], value))
        except Exception as error:
            self.send(400, {'error': str(error) if isinstance(error, ControlError) else 'Операция не принята.'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--directory', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[2]
    configuration = Configuration(args.directory or root / '.cloud-control')
    lock_file = (configuration.directory / 'server.lock').open('a')
    try: fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: parser.error('Панель уже запущена для этого каталога.')
    app = Application(root, configuration.directory)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.app = app
    server.daemon_threads = True

    def stop(signum, frame):
        if app.jobs.active:
            print('Операция ещё выполняется. Дождитесь завершения перед остановкой панели.', flush=True)
        else: raise KeyboardInterrupt

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f'Панель управления: http://127.0.0.1:{server.server_port}', flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close(); lock_file.close()


if __name__ == '__main__': main()
