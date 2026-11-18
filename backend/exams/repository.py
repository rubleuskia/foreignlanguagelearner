"""Durable SQLite repository; callers provide an explicit persistent directory."""
from contextlib import contextmanager
import sqlite3
from pathlib import Path

SCHEMA = '''
CREATE TABLE IF NOT EXISTS imports(
 import_id TEXT PRIMARY KEY, owner TEXT NOT NULL, manifest_digest TEXT NOT NULL,
 exam_id TEXT NOT NULL, revision TEXT NOT NULL, package_path TEXT NOT NULL,
 summary_json TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'prepared',
 result_json TEXT, created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS revisions(
 exam_id TEXT NOT NULL, revision TEXT NOT NULL, content_digest TEXT NOT NULL,
 manifest_digest TEXT NOT NULL, package_path TEXT NOT NULL,
 exam_json TEXT NOT NULL, audio_json TEXT, created_at REAL NOT NULL,
 PRIMARY KEY(exam_id,revision)
);
CREATE TABLE IF NOT EXISTS catalog(
 exam_id TEXT PRIMARY KEY, revision TEXT NOT NULL,
 FOREIGN KEY(exam_id,revision) REFERENCES revisions(exam_id,revision)
);
CREATE TABLE IF NOT EXISTS import_transactions(
 owner TEXT NOT NULL, transaction_id TEXT NOT NULL, import_id TEXT NOT NULL,
 manifest_digest TEXT NOT NULL, result_json TEXT NOT NULL,
 PRIMARY KEY(owner,transaction_id)
);
CREATE TABLE IF NOT EXISTS attempts(
 owner TEXT NOT NULL, attempt_id TEXT NOT NULL,
 exam_id TEXT NOT NULL, revision TEXT NOT NULL, version INTEGER NOT NULL,
 data_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
 PRIMARY KEY(owner,attempt_id),
 FOREIGN KEY(exam_id,revision) REFERENCES revisions(exam_id,revision)
);
CREATE TABLE IF NOT EXISTS attempt_changes(
 owner TEXT NOT NULL, attempt_id TEXT NOT NULL, change_id TEXT NOT NULL,
 request_digest TEXT NOT NULL, PRIMARY KEY(owner,attempt_id,change_id),
 FOREIGN KEY(owner,attempt_id) REFERENCES attempts(owner,attempt_id)
);
CREATE INDEX IF NOT EXISTS attempts_owner_updated ON attempts(owner,updated_at DESC);
'''


class Repository:
    def __init__(self,path):
        self.path=Path(path).resolve()
        self.path.parent.mkdir(parents=True,exist_ok=True)
        connection=self.connect()
        try:
            connection.execute('PRAGMA journal_mode=WAL')
            connection.executescript(SCHEMA)
        finally:
            connection.close()

    def connect(self):
        connection=sqlite3.connect(str(self.path),timeout=30,isolation_level=None)
        connection.row_factory=sqlite3.Row
        connection.execute('PRAGMA foreign_keys=ON')
        connection.execute('PRAGMA synchronous=FULL')
        connection.execute('PRAGMA busy_timeout=30000')
        return connection

    @contextmanager
    def transaction(self,write=False):
        connection=self.connect()
        try:
            connection.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()
